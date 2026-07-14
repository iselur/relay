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
run_as_worker_root() { # $1 = shell snippet run as fake-root inside the namespace
  sudo -u codex-worker /usr/bin/bwrap --unshare-user --uid 0 --gid 0 \
    --bind / / --proc /proc --dev /dev /bin/sh -c "$1" 2>&1
}

echo "== U1: worker with fake root in a user namespace cannot read the operator's credentials"
for secret in "$SENT" "$OP_HOME/.config/gh/hosts.yml" "$OP_HOME/.claude.json" "$OP_HOME/.ssh/id_ed25519"; do
  [ -e "$secret" ] || { echo "  skip $secret — absent on this box (nothing proved, NOT a pass)"; continue; }
  out=$(run_as_worker_root "cat '$secret'")
  if printf '%s' "$out" | grep -qi 'permission denied\|no such file'; then
    ok "read $secret — denied"
  else
    bad "read $secret — WAS READABLE via bwrap userns (escalation path: stop dispatching)"
  fi
done

echo "== U2: worker with fake root in a user namespace cannot write into the operator's home"
canary="$OP_HOME/PWNED_VIA_USERNS"
run_as_worker_root "touch '$canary'" >/dev/null 2>&1
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
