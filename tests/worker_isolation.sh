#!/usr/bin/env bash
# D5 — the security acceptance test. Proves EMPIRICALLY that the codex-worker isolation actually
# holds; if any drill fails, D5 is theater and this exits non-zero. These are OS-level drills
# needing sudo + the codex-worker user, so they run on the box and SKIP LOUDLY in CI.
#
# Anti-vacuity design (dev-box feedback R51 + round-1 review): the operator is resolved, never
# hardcoded; an owner-only sentinel guarantees at least one real read assertion; every service
# probe writes an explicit verdict marker into the drill worktree — a probe that never reported
# is a FAILURE, never a pass; the network drill reads the interface list, not DNS behaviour.
set -uo pipefail
cd "$(dirname "$0")/.."

WORKER=codex-worker
if ! id "$WORKER" >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "SKIP worker_isolation.sh: codex-worker user or passwordless sudo absent (box-only; run scripts/setup-worker-user.sh)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

# The operator whose credentials the drills probe — resolved like setup-worker-user.sh. A
# hardcoded /home/<author> made D1-D3 vacuous on every other box: InaccessiblePaths on a missing
# path kills each probe unit with exit 226, so every deny "passed" without proving anything.
OPERATOR="${ORCH_OPERATOR_USER:-$(id -un)}"
if [ "$OPERATOR" = root ]; then
  echo "SKIP worker_isolation.sh: operator resolved to root; run as the operator or set ORCH_OPERATOR_USER"
  exit 77
fi
OPERATOR_HOME="$(getent passwd "$OPERATOR" | cut -d: -f6)"
if [ -z "$OPERATOR_HOME" ] || [ ! -d "$OPERATOR_HOME" ]; then
  echo "SKIP worker_isolation.sh: cannot resolve home for operator '$OPERATOR' from passwd"
  exit 77
fi
echo "operator: $OPERATOR ($OPERATOR_HOME)"

# Owner-only sentinel: exists on EVERY box, so the read drills always assert something real even
# when a listed credential file is absent (a cat of a missing file "fails" without proving DAC).
SENTINEL="$OPERATOR_HOME/.d5-drill-sentinel"
echo "d5-sentinel $(date +%s)" > "$SENTINEL" && chmod 600 "$SENTINEL" || { echo "FAIL cannot create sentinel"; exit 1; }
trap 'rm -f "$SENTINEL"' EXIT

fails=0
ok(){ echo "ok   $*"; }
bad(){ echo "FAIL $*"; fails=$((fails+1)); }
# assert a direct (non-service) command FAILS. Exit 226 = the probe never ran: vacuous, a failure.
deny(){ local desc="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq 0 ]; then bad "$desc (SUCCEEDED — isolation broken)"
  elif [ "$rc" -eq 226 ]; then bad "$desc — probe never ran (exit 226); vacuous, not a denial"
  else ok "$desc — denied"; fi; }
# read a probe's verdict marker: $1 marker file, $2 description, $3 verdict meaning "denied/blocked"
verdict(){ local marker="$1" desc="$2" want="$3" got
  got="$(cat "$marker" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then ok "$desc"
  elif [ -z "$got" ]; then bad "$desc — probe never reported (vacuous; unit likely failed to start)"
  else bad "$desc — probe reported '$got' (isolation broken)"; fi; }

# Positive control FIRST (round-2 review): `sudo -n true` proves sudo, not that commands run AS
# THE WORKER — if `sudo -u` itself were broken, every denial below would be vacuous.
echo "== D1 harness: positive control — sudo executes commands as $WORKER"
if sudo -n -u "$WORKER" cat /etc/hostname >/dev/null 2>&1; then
  ok "sudo -u $WORKER runs commands (denials below are meaningful)"
else
  echo "FAIL positive control: cannot run commands as $WORKER — every D1 denial would be vacuous"
  exit 1
fi

echo "== D1: codex-worker is denied every operator credential (DAC)"
deny "read sentinel $SENTINEL (owner-only, always present)" sudo -u "$WORKER" cat "$SENTINEL"
for f in "$OPERATOR_HOME/.config/gh/hosts.yml" "$OPERATOR_HOME/.codex/auth.json" \
         "$OPERATOR_HOME/.claude.json" "$OPERATOR_HOME/.ssh/id_ed25519"; do
  if sudo test -e "$f"; then deny "read $f" sudo -u "$WORKER" cat "$f"
  else echo "skip read $f — absent on this box (nothing proved, NOT a pass)"; fi
done
deny "traverse $OPERATOR_HOME" sudo -u "$WORKER" ls "$OPERATOR_HOME"

svc(){ sudo -n systemd-run --uid="$WORKER" --gid="$WORKER" --pipe --wait --quiet --collect \
        --unit="d5probe-$1" --property=ProtectSystem=strict \
        --property=InaccessiblePaths="$OPERATOR_HOME" \
        --property=PrivateTmp=yes --property=NoNewPrivileges=yes "${@:2}"; }

# Positive control FIRST: if a hardened probe service cannot run at all, every verdict below
# would be missing — bail loudly with the probe's own stderr instead of certifying nothing.
echo "== D2/D3 harness: positive control — hardened service CAN write its own worktree"
WT=/srv/codexwork/worktrees/_isodrill
sudo rm -rf "$WT"
if ! mkdir -p "$WT" || ! setfacl -m u:"$WORKER":rwx "$WT"; then
  echo "FAIL cannot prepare drill worktree $WT (run scripts/setup-worker-user.sh)"; exit 1
fi
if err="$(svc w3 --property=ReadWritePaths="$WT" bash -c "echo ok > $WT/in.txt" 2>&1)" && [ -f "$WT/in.txt" ]; then
  ok "write inside worktree — allowed (positive control)"
else
  bad "positive control: cannot write its own worktree — probe services do not run"
  echo "     probe stderr: ${err:-(empty)}"
  sudo rm -rf "$WT"
  echo; echo "FAIL: worker isolation drills (harness broken; $fails failed)"; exit 1
fi

echo "== D2: hardened worker service cannot read the operator's home"
svc r1 --property=ReadWritePaths="$WT" bash -c \
  "if cat '$SENTINEL' >/dev/null 2>&1; then echo LEAK; else echo DENIED; fi > '$WT/m-read'" >/dev/null 2>&1
verdict "$WT/m-read" "service read of operator sentinel — denied" DENIED
svc r2 --property=ReadWritePaths="$WT" bash -c \
  "if ls '$OPERATOR_HOME' >/dev/null 2>&1; then echo LEAK; else echo DENIED; fi > '$WT/m-list'" >/dev/null 2>&1
verdict "$WT/m-list" "service list of operator home — denied" DENIED

echo "== D3: hardened worker service cannot write outside its worktree"
svc w1 --property=ReadWritePaths="$WT" bash -c \
  "if echo x > '$OPERATOR_HOME/PWNED' 2>/dev/null; then echo WROTE; else echo BLOCKED; fi > '$WT/m-homewrite'" >/dev/null 2>&1
[ -e "$OPERATOR_HOME/PWNED" ] && { bad "wrote $OPERATOR_HOME/PWNED"; sudo rm -f "$OPERATOR_HOME/PWNED"; } \
  || verdict "$WT/m-homewrite" "write $OPERATOR_HOME/PWNED — blocked" BLOCKED
svc w2 --property=ReadWritePaths="$WT" bash -c \
  "if echo x > /etc/PWNED 2>/dev/null; then echo WROTE; else echo BLOCKED; fi > '$WT/m-etcwrite'" >/dev/null 2>&1
[ -e /etc/PWNED ] && { bad "wrote /etc/PWNED"; sudo rm -f /etc/PWNED; } \
  || verdict "$WT/m-etcwrite" "write /etc/PWNED — blocked" BLOCKED

echo "== D4: the gate-test service (PrivateNetwork=yes) sees only loopback"
svc net --property=PrivateNetwork=yes --property=ReadWritePaths="$WT" bash -c \
  "ls /sys/class/net > '$WT/m-net' 2>/dev/null" >/dev/null 2>&1
ifaces="$(tr '\n' ' ' < "$WT/m-net" 2>/dev/null || true)"
case "$ifaces" in
  "lo ") ok "test-phase network — only loopback (PrivateNetwork proven directly)";;
  "")    bad "network probe never reported (vacuous)";;
  *)     bad "test-phase sees interfaces: $ifaces(network NOT private)";;
esac
sudo rm -rf "$WT"

echo "== D5: worktree path-safety gate rejects planted symlinks/special files"
if OPERATOR_HOME="$OPERATOR_HOME" .venv/bin/python - <<'PY'
import importlib.util, tempfile, os, pathlib, sys
s=importlib.util.spec_from_file_location("d","scripts/dispatch.py");d=importlib.util.module_from_spec(s);s.loader.exec_module(d)
wt=pathlib.Path(tempfile.mkdtemp())
(wt/"ok.txt").write_text("fine")
os.symlink(os.path.join(os.environ["OPERATOR_HOME"], ".config/gh/hosts.yml"), wt/"evil")   # planted symlink to an operator secret
os.mkfifo(wt/"pipe")
bad=d.validate_worktree_safe(wt)
sys.exit(0 if ("evil" in bad and "pipe" in bad and "ok.txt" not in bad) else 1)
PY
then ok "validate_worktree_safe flags symlink+fifo, passes normal file"; else bad "path-safety gate missed a planted entry"; fi

echo
if [ "$fails" = 0 ]; then echo "PASS: worker isolation drills (0 failed)"; exit 0
else echo "FAIL: worker isolation drills ($fails failed)"; exit 1; fi
