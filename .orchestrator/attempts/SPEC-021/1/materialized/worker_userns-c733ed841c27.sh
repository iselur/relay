#!/usr/bin/env bash
# The box runs Ubuntu's packaged `bwrap-userns-restrict` AppArmor profile so Codex can build its
# own sandbox (without it, every Codex run dies at `bwrap: loopback: Failed RTM_NEWADDR` — that
# defect silently killed an entire night of delegated work). The profile is attached to the
# binary, not to a user: the codex-worker user can invoke bwrap too. That is intended (the worker
# runs Codex), but it means "the worker gained a new capability" — so the isolation claim must be
# re-proven against it, not assumed. This drill does exactly that: a worker holding fake root
# inside its own user namespace still cannot read or write the operator's home.
#
# Box-only (needs the codex-worker user + sudo); SKIPs in CI.
set -uo pipefail

command -v bwrap >/dev/null 2>&1 || { echo "SKIP worker_userns.sh: bwrap absent"; exit 77; }
id codex-worker >/dev/null 2>&1 || { echo "SKIP worker_userns.sh: codex-worker user absent"; exit 77; }
sudo -n true 2>/dev/null || { echo "SKIP worker_userns.sh: passwordless sudo unavailable"; exit 77; }

OP_HOME=$(getent passwd "${ORCH_OPERATOR_USER:-$(id -un)}" | cut -d: -f6)
[ -n "$OP_HOME" ] && [ -d "$OP_HOME" ] || { echo "SKIP worker_userns.sh: cannot resolve operator home"; exit 77; }

# Owner-only sentinel so U1 always executes at least one read assertion, even on a box where
# every listed credential file is absent (round-1 review: zero assertions must never PASS).
SENT="$OP_HOME/.userns-drill-sentinel"
echo "userns-sentinel" > "$SENT" && chmod 600 "$SENT" || { echo "FAIL cannot create sentinel"; exit 1; }
trap 'rm -f "$SENT"' EXIT
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

# The worker maps itself to uid 0 inside a fresh user namespace and binds the whole filesystem.
# That fake root is namespace-local: outside the namespace it is still codex-worker, so the
# operator's home stays unreadable. If this ever succeeds, the userns exception has become an
# escalation path and dispatch must stop.
# Runs a snippet as fake-root inside the namespace with POSITIONAL args (never string-interpolated),
# so a target path containing shell metacharacters (an apostrophe in OP_HOME) cannot alter what runs.
# The snippet references "$1", "$2", … ; args after it are passed through to bwrap's /bin/sh.
run_as_worker_root() { # $1 = sh snippet; $2.. = positional args for the snippet
  local snippet="$1"; shift
  sudo -u codex-worker /usr/bin/bwrap --unshare-user --uid 0 --gid 0 \
    --bind / / --proc /proc --dev /dev /bin/sh -c "$snippet" sh "$@" 2>&1
}

echo "== U1: worker with fake root in a user namespace cannot read the operator's credentials"
# Classify each read by cat's EXIT STATUS, not by denial TEXT, inside a NONCE-tagged frame (B5).
# Two failure modes the old text-grep conflated:
#   1. a bwrap that cannot start prints "Creating new namespace failed: Permission denied" — the old
#      grep scored that as "denied" = isolation proven, certifying a sandbox that never ran;
#   2. a genuinely readable secret whose CONTENT happens to contain "permission denied" spoofs it.
# Fix: a random per-run NONCE frames the payload (secret bytes cannot forge it), the target is a
# POSITIONAL arg (no shell-source interpolation), and we judge by cat's own exit code read from
# inside the frame — which must be a VALIDATED numeric trailer, else the read is UNPROVEN (BAD):
#   frame present + numeric ec!=0 => bwrap ran and the read was denied;
#   ec==0 => the secret WAS readable (escalation); frame/ec absent or malformed => sandbox suspect.
NONCE=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
# The exit code is bounded by the nonce on BOTH sides — <NONCE>E:<digits><NONCE>Z — so the numeric
# field is anchored and no trailing byte can smuggle a non-numeric suffix past the parser (round-3
# hardening: a trailer like E:7x is rejected because 'x' is not the closing nonce).
framed_read() { run_as_worker_root 'printf "%sB" "$1"; cat "$2" 2>/dev/null; ec=$?; printf "%sE:%d%sZ" "$1" "$ec" "$1"' "$NONCE" "$1"; }
frame_ec()   { printf '%s' "$1" | tr -d '\n' | sed -n "s/.*${NONCE}E:\([0-9][0-9]*\)${NONCE}Z.*/\1/p"; }
has_frame()  { printf '%s' "$1" | tr -d '\n' | grep -q "${NONCE}B.*${NONCE}E:[0-9][0-9]*${NONCE}Z"; }
is_num()     { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

CTRL=$(mktemp); printf 'userns-positive-control-%s' "$$" > "$CTRL"; chmod 644 "$CTRL"
trap 'rm -f "$SENT" "$CTRL"' EXIT
ctrl_out=$(framed_read "$CTRL")
if has_frame "$ctrl_out" && [ "$(frame_ec "$ctrl_out")" = "0" ] \
   && printf '%s' "$ctrl_out" | grep -q "userns-positive-control-$$"; then
  ok "positive control: bwrap started, entered the namespace, and read a permitted file (cat exit 0)"
  BWRAP_RUNS=1
else
  bad "positive control FAILED: bwrap did not execute our command (broken sandbox — isolation UNPROVEN, not a pass)"
  BWRAP_RUNS=0
fi

for secret in "$SENT" "$OP_HOME/.config/gh/hosts.yml" "$OP_HOME/.claude.json" "$OP_HOME/.ssh/id_ed25519"; do
  [ -e "$secret" ] || { echo "  skip $secret — absent on this box (nothing proved, NOT a pass)"; continue; }
  [ "$BWRAP_RUNS" -eq 1 ] || { bad "cannot test $secret — sandbox broken (see positive control)"; continue; }
  out=$(framed_read "$secret")
  ec=$(frame_ec "$out")
  if ! has_frame "$out" || ! is_num "$ec"; then
    bad "read $secret — no valid nonce frame / exit trailer (sandbox did not run the read cleanly; UNPROVEN)"
  elif [ "$ec" != "0" ]; then
    ok "read $secret — bwrap ran and the read was denied (cat exit $ec)"
  else
    bad "read $secret — WAS READABLE via bwrap userns (escalation path: stop dispatching)"
  fi
done

echo "== U2: worker with fake root in a user namespace cannot write into the operator's home"
canary="$OP_HOME/PWNED_VIA_USERNS"
run_as_worker_root 'touch "$1"' "$canary" >/dev/null 2>&1
if [ -e "$canary" ]; then
  bad "write $canary — SUCCEEDED via bwrap userns (escalation path: stop dispatching)"
  rm -f "$canary"
else
  ok "write $canary — blocked"
fi

echo "== U3: the userns exception is the packaged capability-stripping profile, not a global opt-out"
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = "1" ]; then
  ok "kernel userns restriction still ON (the fix is a scoped profile, not the global sysctl)"
else
  bad "kernel userns restriction is OFF — the global sysctl was used; the scoped profile is required"
fi
if sudo aa-status 2>/dev/null | grep -qx '   unpriv_bwrap'; then
  ok "unpriv_bwrap profile loaded (bwrap's children run without capabilities)"
else
  bad "unpriv_bwrap profile NOT loaded — bwrap children would keep capabilities"
fi

[ "$fails" -eq 0 ] && echo "PASS worker_userns.sh" || echo "FAIL worker_userns.sh"
exit "$fails"
