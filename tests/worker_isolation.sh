#!/usr/bin/env bash
# D5 — the security acceptance test. Proves EMPIRICALLY that the codex-worker isolation actually
# holds; if any drill fails, D5 is theater and this exits non-zero. These are OS-level drills
# needing sudo + the codex-worker user, so they run on the box and SKIP LOUDLY in CI.
set -uo pipefail
cd "$(dirname "$0")/.."

WORKER=codex-worker
if ! id "$WORKER" >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "SKIP worker_isolation.sh: codex-worker user or passwordless sudo absent (box-only; run scripts/setup-worker-user.sh)"
  exit 0
fi

fails=0
ok(){ echo "ok   $*"; }
bad(){ echo "FAIL $*"; fails=$((fails+1)); }
# assert a command FAILS (worker must be denied)
deny(){ local desc="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$desc (SUCCEEDED — isolation broken)"; else ok "$desc — denied"; fi; }

echo "== D1: codex-worker is denied every val credential (DAC)"
for f in /home/val/.config/gh/hosts.yml /home/val/.codex/auth.json /home/val/.claude.json /home/val/.ssh/id_ed25519; do
  deny "read $f" sudo -u "$WORKER" cat "$f"
done
deny "traverse /home/val" sudo -u "$WORKER" ls /home/val

echo "== D2: hardened worker service cannot read /home/val even with a bind-mount attempt"
svc(){ sudo -n systemd-run --uid="$WORKER" --gid="$WORKER" --pipe --wait --quiet --collect \
        --unit="d5probe-$1" --property=ProtectSystem=strict --property=InaccessiblePaths=/home/val \
        --property=PrivateTmp=yes --property=NoNewPrivileges=yes "${@:2}"; }
deny "service read gh token" svc r1 bash -c 'cat /home/val/.config/gh/hosts.yml'

echo "== D3: hardened worker service cannot write outside its worktree"
WT=/srv/codexwork/worktrees/_isodrill
sudo rm -rf "$WT"; mkdir -p "$WT"; setfacl -m u:$WORKER:rwx "$WT"
svc w1 --property=ReadWritePaths="$WT" bash -c 'echo x > /home/val/PWNED' >/dev/null 2>&1
[ -e /home/val/PWNED ] && { bad "wrote /home/val/PWNED"; sudo rm -f /home/val/PWNED; } || ok "write /home/val/PWNED — blocked"
svc w2 --property=ReadWritePaths="$WT" bash -c 'echo x > /etc/PWNED' >/dev/null 2>&1
[ -e /etc/PWNED ] && { bad "wrote /etc/PWNED"; sudo rm -f /etc/PWNED; } || ok "write /etc/PWNED — blocked"
# positive control: it CAN write its own worktree
if svc w3 --property=ReadWritePaths="$WT" bash -c "echo ok > $WT/in.txt" >/dev/null 2>&1 && [ -f "$WT/in.txt" ]; then
  ok "write inside worktree — allowed (positive control)"; else bad "cannot write its own worktree"; fi
sudo rm -rf "$WT"

echo "== D4: the gate-test service (PrivateNetwork=yes) has no network"
if sudo -n systemd-run --uid="$WORKER" --gid="$WORKER" --pipe --wait --quiet --collect \
     --unit=d5probe-net --property=PrivateNetwork=yes --property=InaccessiblePaths=/home/val \
     bash -c 'getent ahosts api.github.com' >/dev/null 2>&1; then
  bad "test-phase resolved api.github.com (network NOT off)"; else ok "test-phase network — off"; fi

echo "== D5: worktree path-safety gate rejects planted symlinks/special files"
if .venv/bin/python - <<'PY'
import importlib.util, tempfile, os, pathlib, sys
s=importlib.util.spec_from_file_location("d","scripts/dispatch.py");d=importlib.util.module_from_spec(s);s.loader.exec_module(d)
wt=pathlib.Path(tempfile.mkdtemp())
(wt/"ok.txt").write_text("fine")
os.symlink("/home/val/.config/gh/hosts.yml", wt/"evil")   # planted symlink to a val secret
os.mkfifo(wt/"pipe")
bad=d.validate_worktree_safe(wt)
sys.exit(0 if ("evil" in bad and "pipe" in bad and "ok.txt" not in bad) else 1)
PY
then ok "validate_worktree_safe flags symlink+fifo, passes normal file"; else bad "path-safety gate missed a planted entry"; fi

echo
if [ "$fails" = 0 ]; then echo "PASS: worker isolation drills (0 failed)"; exit 0
else echo "FAIL: worker isolation drills ($fails failed)"; exit 1; fi
