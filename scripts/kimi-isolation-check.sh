#!/usr/bin/env bash
# Kimi brief, slice 4 — the kimi ACTIVATION GATE (owner/operator, run on the target host).
# Proves EMPIRICALLY, on this box, both sides of the kimi credential boundary. Per the brief's
# Isolation gate this is an OWNER/OPERATOR host action (run it after scripts/setup-worker-user.sh),
# NOT a dispatcher per-launch box-precondition: an unconditional box-precondition returning 77
# would abort EVERY vendor's launch (dispatch.py requires PASS from all box tests), so this
# lives in scripts/ and is invoked by hand, not by scripts/test — round-1 review, high 2.
#
# CONTRACT: kimi workers may be activated only after this exits 0 on THIS host. Any non-zero
# exit — including the 77 "did not run" ladder below — means kimi activation STAYS PROHIBITED
# (a skip is never evidence of a pass; T1/R26). Drills:
#   K1  codex-worker (DAC) cannot read the operator's kimi credential or list ~/.kimi-code.
#   K2  the provisioned ~codex-worker/.kimi-code is EXACTLY {700 dir, 700 credentials dir,
#       600 config.toml, 600 credentials/kimi-code.json}, all codex-worker-owned — no extra,
#       missing, or non-regular (symlink/FIFO/socket) entries.
#   K3  the hardened service reads AND writes the worker's own kimi state (the dispatcher rw path).
#   K4  the hardened service cannot reach the operator's kimi credential.
#   K5  the DISPATCHER-VETTED native binary (resolved via worker_kimi_runtime — same ELF/trust
#       checks the launch path uses) executes --version, bound to /opt/kimi/kimi under the
#       service hardening. Unvetted output is never echoed.
# Anti-vacuity: positive controls first, explicit verdict markers, operator resolved not hardcoded.
set -uo pipefail
cd "$(dirname "$0")/.."

WORKER=codex-worker
WORKER_HOME=/home/$WORKER
PROHIBIT="kimi activation stays PROHIBITED"

if ! id "$WORKER" >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "SKIP: codex-worker user or passwordless sudo absent (run scripts/setup-worker-user.sh); $PROHIBIT"
  exit 77
fi

OPERATOR="${ORCH_OPERATOR_USER:-$(id -un)}"
if [ "$OPERATOR" = root ]; then
  echo "SKIP: operator resolved to root; run as the operator or set ORCH_OPERATOR_USER; $PROHIBIT"
  exit 77
fi
OPERATOR_HOME="$(getent passwd "$OPERATOR" | cut -d: -f6)"
if [ -z "$OPERATOR_HOME" ] || [ ! -d "$OPERATOR_HOME" ]; then
  echo "SKIP: cannot resolve home for operator '$OPERATOR' from passwd; $PROHIBIT"
  exit 77
fi
echo "operator: $OPERATOR ($OPERATOR_HOME)"

OP_CRED="$OPERATOR_HOME/.kimi-code/credentials/kimi-code.json"
if [ ! -f "$OP_CRED" ]; then
  echo "SKIP: operator has no kimi credential ($OP_CRED); kimi is not installed on this box; $PROHIBIT"
  exit 77
fi
if ! sudo test -f "$WORKER_HOME/.kimi-code/credentials/kimi-code.json"; then
  echo "SKIP: worker kimi state not provisioned; run scripts/setup-worker-user.sh; $PROHIBIT"
  exit 77
fi

# The dispatcher's OWN resolver picks and vets the native binary (ELF magic, owner/mode,
# ancestry, ACLs) exactly as the launch path does — this gate must prove THAT binary runs, not
# an ad-hoc `-x` guess (round-1 review, medium 4). Absent trusted runtime -> cannot vet -> skip.
TRUNTIME=/opt/orchestrator-test-runtime
if [ "$(sudo stat -c '%U:%G' "$TRUNTIME" 2>/dev/null)" != root:root ]; then
  echo "SKIP: trusted python runtime $TRUNTIME absent/not root-owned (run scripts/setup-worker-user.sh); $PROHIBIT"
  exit 77
fi
KIMI_BIN="$(ORCH_OPERATOR_USER="$OPERATOR" "$TRUNTIME/bin/python" - <<'PY'
import importlib.util, pathlib
s = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(s); s.loader.exec_module(d)
rt = d.worker_kimi_runtime()          # (argv, [(real_src, /opt/kimi/kimi)], entry) or None
print(rt[1][0][0] if rt else "")
PY
)"
if [ -z "$KIMI_BIN" ] || ! sudo test -f "$KIMI_BIN"; then
  echo "SKIP: no dispatcher-vetted native kimi runtime on this box (worker_kimi_runtime found none); $PROHIBIT"
  exit 77
fi
echo "dispatcher-vetted kimi binary: $KIMI_BIN"

fails=0
ok(){ echo "ok   $*"; }
bad(){ echo "FAIL $*"; fails=$((fails+1)); }
deny(){ local desc="$1"; shift; "$@" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq 0 ]; then bad "$desc (SUCCEEDED — isolation broken)"
  elif [ "$rc" -eq 226 ]; then bad "$desc — probe never ran (exit 226); vacuous, not a denial"
  else ok "$desc — denied"; fi; }
verdict(){ local marker="$1" desc="$2" want="$3" got
  got="$(cat "$marker" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then ok "$desc"
  elif [ -z "$got" ]; then bad "$desc — probe never reported (vacuous; unit likely failed to start)"
  else bad "$desc — probe reported '$got' (isolation broken)"; fi; }

echo "== K0 harness: positive control — sudo executes commands as $WORKER"
if sudo -n -u "$WORKER" cat /etc/hostname >/dev/null 2>&1; then
  ok "sudo -u $WORKER runs commands (denials below are meaningful)"
else
  echo "FAIL positive control: cannot run commands as $WORKER — every denial would be vacuous; $PROHIBIT"
  exit 1
fi

echo "== K1: codex-worker is denied the operator's kimi credential (DAC)"
deny "read $OP_CRED" sudo -u "$WORKER" cat "$OP_CRED"
deny "traverse $OPERATOR_HOME/.kimi-code" sudo -u "$WORKER" ls "$OPERATOR_HOME/.kimi-code"

echo "== K2: the worker's provisioned kimi state is EXACTLY the required tree (no extra/foreign entries)"
# %y is the type: d/f/l/... — anything but the four expected regular entries fails, INCLUDING a
# symlink (which the credential precheck's `test -f` would have followed — round-1 review, high 3).
# `find` errors (permission/vanished) print to stderr and are turned into an explicit failure;
# zero output is NOT silently treated as success.
mapfile -t ST < <(sudo find "$WORKER_HOME/.kimi-code" -mindepth 0 \
                    -printf '%y %m %u:%g %P\n' 2>/tmp/kimi-k2-err.$$; echo "rc=$?")
find_rc="${ST[-1]#rc=}"; unset 'ST[-1]'
if [ "$find_rc" != 0 ] || [ -s /tmp/kimi-k2-err.$$ ]; then
  bad "find over the worker kimi state errored (rc=$find_rc): $(cat /tmp/kimi-k2-err.$$ 2>/dev/null)"
fi
rm -f /tmp/kimi-k2-err.$$
# Exact membership: the root dir (empty %P), config.toml, credentials dir, and the credential.
want="$(printf '%s\n' \
  "d 700 :$WORKER:$WORKER" \
  "f 600 config.toml:$WORKER:$WORKER" \
  "d 700 credentials:$WORKER:$WORKER" \
  "f 600 credentials/kimi-code.json:$WORKER:$WORKER" | sort)"
have="$(printf '%s\n' "${ST[@]}" | awk '{print $1" "$2" "$4":"$3}' | sort)"
if [ "$have" = "$want" ]; then
  ok "worker kimi state is exactly {700 ., 600 config.toml, 700 credentials, 600 credential}, owned $WORKER"
else
  bad "worker kimi state does not match the required tree"
  echo "--- expected"; printf '%s\n' "$want"
  echo "--- observed"; printf '%s\n' "$have"
fi

WT=/srv/codexwork/worktrees/_kimidrill
sudo rm -rf "$WT"
if ! mkdir -p "$WT" || ! setfacl -m u:"$WORKER":rwx "$WT"; then
  echo "FAIL cannot prepare drill worktree $WT (run scripts/setup-worker-user.sh); $PROHIBIT"; exit 1
fi
svc(){ sudo -n systemd-run --uid="$WORKER" --gid="$WORKER" --pipe --wait --quiet --collect \
        --unit="kimicheck-$1" --property=ProtectSystem=strict \
        --property=InaccessiblePaths="$OPERATOR_HOME" \
        --property=PrivateTmp=yes --property=NoNewPrivileges=yes \
        --setenv=HOME="$WORKER_HOME" "${@:2}"; }

echo "== K3 harness: positive control — hardened service CAN write its own worktree"
if err="$(svc w0 --property=ReadWritePaths="$WT" bash -c "echo ok > $WT/in.txt" 2>&1)" && [ -f "$WT/in.txt" ]; then
  ok "write inside worktree — allowed (positive control)"
else
  bad "positive control: cannot write its own worktree — probe services do not run"
  echo "     probe stderr: ${err:-(empty)}"; sudo rm -rf "$WT"
  echo; echo "FAIL: kimi isolation drills (harness broken; $fails failed); $PROHIBIT"; exit 1
fi

echo "== K3: hardened service reads AND writes the worker's own kimi state (the dispatcher rw path)"
svc k3 --property=ReadWritePaths="$WT" --property=ReadWritePaths="$WORKER_HOME/.kimi-code" bash -c \
  "if cat '$WORKER_HOME/.kimi-code/credentials/kimi-code.json' >/dev/null 2>&1 \
      && touch '$WORKER_HOME/.kimi-code/.drill-write' 2>/dev/null; then echo READY; else echo BROKEN; fi > '$WT/m-state'" >/dev/null 2>&1
verdict "$WT/m-state" "worker kimi state readable and writable inside the service" READY
sudo rm -f "$WORKER_HOME/.kimi-code/.drill-write"

echo "== K4: hardened service cannot reach the operator's kimi credential"
svc k4 --property=ReadWritePaths="$WT" bash -c \
  "if cat '$OP_CRED' >/dev/null 2>&1; then echo LEAK; else echo DENIED; fi > '$WT/m-opcred'" >/dev/null 2>&1
verdict "$WT/m-opcred" "service read of operator kimi credential — denied" DENIED

echo "== K5: the DISPATCHER-VETTED native kimi binary executes under service hardening"
# The resolved real binary bind-mounted RO to /opt/kimi/kimi, argv execs the destination —
# exactly the slice-3 launch shape. --version needs no credential or network. Only the marker
# is inspected; the binary's own output is never echoed (it is not guaranteed credential-free).
svc k5 --property=PrivateNetwork=yes --property=ReadWritePaths="$WT" \
  --property=BindReadOnlyPaths="$KIMI_BIN:/opt/kimi/kimi" bash -c \
  "if /opt/kimi/kimi --version >/dev/null 2>&1; then echo READY; else echo BROKEN; fi > '$WT/m-exec'" >/dev/null 2>&1
verdict "$WT/m-exec" "bound dispatcher-vetted kimi binary executes under service hardening" READY
sudo rm -rf "$WT"

echo
if [ "$fails" = 0 ]; then echo "PASS: kimi isolation drills (0 failed) — kimi activation permitted on this host"; exit 0
else echo "FAIL: kimi isolation drills ($fails failed); $PROHIBIT"; exit 1; fi
