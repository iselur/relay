#!/usr/bin/env bash
# D5 — the security acceptance test. Proves EMPIRICALLY that the codex-worker isolation actually
# holds; if any drill fails, D5 is theater and this exits non-zero. These are OS-level drills
# needing sudo + the codex-worker user, so they run on the box and SKIP LOUDLY in CI.
set -uo pipefail
cd "$(dirname "$0")/.."

WORKER=codex-worker
if ! id "$WORKER" >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "SKIP worker_isolation.sh: codex-worker user or passwordless sudo absent (box-only; run scripts/setup-worker-user.sh)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

# The operator whose credentials the drills probe — resolved like setup-worker-user.sh, never
# hardcoded. A hardcoded /home/<author> made D1-D3 vacuous on every other box: InaccessiblePaths
# on a missing path kills each probe unit with exit 226, so every deny "passed" without proving
# anything and only the positive control caught it (dev-box feedback, R51).
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

fails=0
ok(){ echo "ok   $*"; }
bad(){ echo "FAIL $*"; fails=$((fails+1)); }
# assert a command FAILS (worker must be denied). Exit 226 is NOT a denial — the probe unit never
# ran (namespace setup failed), which proves nothing.
deny(){ local desc="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq 0 ]; then bad "$desc (SUCCEEDED — isolation broken)"
  elif [ "$rc" -eq 226 ]; then bad "$desc — probe unit failed to start (exit 226); vacuous, not a denial"
  else ok "$desc — denied"; fi; }

echo "== D1: codex-worker is denied every operator credential (DAC)"
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

# Positive control FIRST: if a hardened probe service cannot run at all, every deny below is
# vacuous — bail loudly with the probe's own stderr instead of certifying nothing.
echo "== D2/D3 harness: positive control — hardened service CAN write its own worktree"
WT=/srv/codexwork/worktrees/_isodrill
sudo rm -rf "$WT"
if ! mkdir -p "$WT" || ! setfacl -m u:"$WORKER":rwx "$WT"; then
  echo "FAIL cannot prepare drill worktree $WT (run scripts/setup-worker-user.sh)"; exit 1
fi
if err="$(svc w3 --property=ReadWritePaths="$WT" bash -c "echo ok > $WT/in.txt" 2>&1)" && [ -f "$WT/in.txt" ]; then
  ok "write inside worktree — allowed (positive control)"
else
  bad "positive control: cannot write its own worktree — probe services do not run, denies would be vacuous"
  echo "     probe stderr: ${err:-(empty)}"
  sudo rm -rf "$WT"
  echo; echo "FAIL: worker isolation drills (harness broken; $fails failed)"; exit 1
fi

echo "== D2: hardened worker service cannot read the operator's home"
deny "service list $OPERATOR_HOME" svc r1 --property=ReadWritePaths="$WT" bash -c "ls '$OPERATOR_HOME'"
if sudo test -e "$OPERATOR_HOME/.config/gh/hosts.yml"; then
  deny "service read gh token" svc r2 --property=ReadWritePaths="$WT" bash -c "cat '$OPERATOR_HOME/.config/gh/hosts.yml'"
fi

echo "== D3: hardened worker service cannot write outside its worktree"
svc w1 --property=ReadWritePaths="$WT" bash -c "echo x > '$OPERATOR_HOME/PWNED'" >/dev/null 2>&1
[ -e "$OPERATOR_HOME/PWNED" ] && { bad "wrote $OPERATOR_HOME/PWNED"; sudo rm -f "$OPERATOR_HOME/PWNED"; } || ok "write $OPERATOR_HOME/PWNED — blocked"
svc w2 --property=ReadWritePaths="$WT" bash -c 'echo x > /etc/PWNED' >/dev/null 2>&1
[ -e /etc/PWNED ] && { bad "wrote /etc/PWNED"; sudo rm -f /etc/PWNED; } || ok "write /etc/PWNED — blocked"
sudo rm -rf "$WT"

echo "== D4: the gate-test service (PrivateNetwork=yes) has no network"
if sudo -n systemd-run --uid="$WORKER" --gid="$WORKER" --pipe --wait --quiet --collect \
     --unit=d5probe-net --property=PrivateNetwork=yes --property=InaccessiblePaths="$OPERATOR_HOME" \
     bash -c 'getent ahosts api.github.com' >/dev/null 2>&1; then
  bad "test-phase resolved api.github.com (network NOT off)"; else ok "test-phase network — off"; fi

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
