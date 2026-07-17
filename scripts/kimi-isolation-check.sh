#!/usr/bin/env bash
# Kimi activation gate — owner/operator, run on the host after scripts/setup-worker-user.sh.
#
# THREAT MODEL (bounded by owner decision 2026-07-17: "simplify / risk-accept non-critical").
# This is a MISCONFIGURATION check the owner runs by hand, with dispatch stopped, to confirm the
# kimi credential boundary and worker state are set up correctly before enabling a kimi role.
# It is NOT an adversary-proof verdict oracle: it does NOT defend against a LIVE malicious process
# already running as codex-worker during the check (forging a verdict via signals, /proc pipe
# injection, or planted filenames). That scenario already means the codex-worker UID is
# compromised — a far larger breach than this gate is meant to detect — so it is deliberately out
# of scope. The checks are therefore plain exit-status assertions run as the worker UID and as the
# hardened service; the owner stops dispatch first (advisory quiescence below).
#
# What it DOES prove: the operator's kimi credential is unreadable by the worker UID and by the
# hardened service envelope; the worker's own provisioned state has the right ownership/modes; the
# service can use that state; and the dispatcher-vetted native binary runs under the service.
#
# Contract: exit 0 is required before the first kimi worker launch. Any non-zero — including the
# 77 "did not run" preconditions — means kimi activation stays PROHIBITED.
set -uo pipefail
cd "$(dirname "$0")/.."

WORKER=codex-worker
WORKER_HOME=/home/$WORKER
WKIMI="$WORKER_HOME/.kimi-code"
PROHIBIT="kimi activation stays PROHIBITED"

# ---- preconditions: 77 = did not run (never a pass) ------------------------------------------
if ! id "$WORKER" >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "SKIP: codex-worker user or passwordless sudo absent (run scripts/setup-worker-user.sh); $PROHIBIT"; exit 77
fi
OPERATOR="${ORCH_OPERATOR_USER:-$(id -un)}"
[ "$OPERATOR" = root ] && { echo "SKIP: operator resolved to root; run as the operator or set ORCH_OPERATOR_USER; $PROHIBIT"; exit 77; }
OPERATOR_HOME="$(getent passwd "$OPERATOR" | cut -d: -f6)"
{ [ -n "$OPERATOR_HOME" ] && [ -d "$OPERATOR_HOME" ]; } || { echo "SKIP: cannot resolve operator home from passwd; $PROHIBIT"; exit 77; }
echo "operator: $OPERATOR ($OPERATOR_HOME)"
OP_CRED="$OPERATOR_HOME/.kimi-code/credentials/kimi-code.json"
[ -f "$OP_CRED" ] || { echo "SKIP: operator has no kimi credential ($OP_CRED); kimi is not installed on this box; $PROHIBIT"; exit 77; }
sudo test -f "$WKIMI/credentials/kimi-code.json" || { echo "SKIP: worker kimi state not provisioned (run scripts/setup-worker-user.sh); $PROHIBIT"; exit 77; }

# The dispatcher's OWN resolver picks and vets the native binary (ELF/owner/mode/ancestry) exactly
# as the launch path does; it ships in slice 3 (worker_kimi_runtime), which must be installed.
TRUNTIME=/opt/orchestrator-test-runtime
[ "$(sudo stat -c '%U:%G' "$TRUNTIME" 2>/dev/null)" = root:root ] || { echo "SKIP: trusted python runtime $TRUNTIME absent/not root-owned (run scripts/setup-worker-user.sh); $PROHIBIT"; exit 77; }
KIMI_BIN="$(ORCH_OPERATOR_USER="$OPERATOR" "$TRUNTIME/bin/python" - <<'PY'
import importlib.util
s = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(s); s.loader.exec_module(d)
fn = getattr(d, "worker_kimi_runtime", None)
if fn is None:
    print("__NO_RESOLVER__")
else:
    rt = fn()
    print(rt[1][0][0] if rt else "")
PY
)"
[ "$KIMI_BIN" = "__NO_RESOLVER__" ] && { echo "SKIP: the installed dispatcher has no kimi runtime resolver yet — install slice 3 (PR #165) first; $PROHIBIT"; exit 77; }
{ [ -n "$KIMI_BIN" ] && sudo test -f "$KIMI_BIN"; } || { echo "SKIP: no dispatcher-vetted native kimi runtime on this box; $PROHIBIT"; exit 77; }
echo "dispatcher-vetted kimi binary: $KIMI_BIN"

# Advisory quiescence: run this gate with dispatch stopped. This is operating procedure, not an
# anti-forgery defense (see threat model) — a simple check that the worker UID is idle.
if sudo -n pgrep -u "$WORKER" >/dev/null 2>&1; then
  echo "SKIP: $WORKER has running processes — stop dispatch and re-run this gate; $PROHIBIT"; exit 77
fi

fails=0
ok(){ echo "ok   $*"; }
bad(){ echo "FAIL $*"; fails=$((fails+1)); }

# svc: run a probe in a hardened transient unit shaped like the worker service; return its exit.
svc(){ sudo -n systemd-run --uid="$WORKER" --gid="$WORKER" --wait --quiet --collect \
        --unit="kimicheck-$1" --property=ProtectSystem=strict \
        --property=InaccessiblePaths="$OPERATOR_HOME" \
        --property=PrivateTmp=yes --property=NoNewPrivileges=yes \
        --setenv=HOME="$WORKER_HOME" "${@:2}" >/dev/null 2>&1; }

echo "== K0 positive controls: the worker UID and the hardened service can run at all"
sudo -n -u "$WORKER" true || { echo "FAIL positive control: cannot run commands as $WORKER; $PROHIBIT"; exit 1; }
svc w0 true || { echo "FAIL positive control: hardened probe unit does not run; $PROHIBIT"; exit 1; }
ok "worker UID and hardened service both run (denials below are meaningful)"

echo "== K1: the worker UID (DAC) cannot read or traverse the operator's kimi state"
if sudo -n -u "$WORKER" cat "$OP_CRED" >/dev/null 2>&1; then bad "worker read $OP_CRED (LEAK)"; else ok "worker denied $OP_CRED"; fi
# Test TRAVERSAL (dir search bit), not listing: a 0711 dir denies `ls` but still lets the worker
# `cd` in and reach known paths, so `cd` is the boundary probe. Success = the boundary is broken.
if sudo -n -u "$WORKER" bash -c "cd -- '$OPERATOR_HOME/.kimi-code'" 2>/dev/null; then bad "worker can traverse operator ~/.kimi-code (LEAK)"; else ok "worker denied traversal of operator ~/.kimi-code"; fi

echo "== K2: the worker's provisioned state has the required ownership and modes"
# The four expected entries, checked individually, plus an exact entry count so a stray file is
# caught. (An adversary planting a symlink or an odd-named file is the out-of-scope live-worker
# scenario; this catches provisioning/permission MISconfiguration.)
chk(){ local rel="$1" wmode="$2" got; local p="$WKIMI${rel:+/$rel}"
  got="$(sudo stat -c '%a %U:%G' -- "$p" 2>/dev/null)"
  [ "$got" = "$wmode $WORKER:$WORKER" ] || bad "K2 ${rel:-.kimi-code}: '$got' (want '$wmode $WORKER:$WORKER')"; }
chk ""                             700
chk config.toml                    600
chk credentials                    700
chk credentials/kimi-code.json     600
n="$(sudo find "$WKIMI" -mindepth 1 2>/dev/null | wc -l)"
[ "$n" -eq 3 ] || bad "K2 worker .kimi-code has $n entries (want exactly 3: config.toml, credentials/, the credential)"

echo "== K3: the hardened service can read AND write the worker's own kimi state"
if svc k3 --property=ReadWritePaths="$WKIMI" bash -c "cat '$WKIMI/credentials/kimi-code.json' >/dev/null 2>&1 && touch '$WKIMI/.drill-write'"; then
  ok "service reads and writes the worker's own kimi state"
else
  bad "service could not read+write the worker's own kimi state"
fi
sudo rm -f "$WKIMI/.drill-write"

echo "== K4: the hardened service cannot read the operator's kimi credential"
if svc k4 bash -c "cat '$OP_CRED' >/dev/null 2>&1"; then bad "service read $OP_CRED (LEAK)"; else ok "service denied $OP_CRED"; fi

echo "== K5: the dispatcher-vetted native kimi binary runs under the service"
# Resolved real binary bind-mounted RO to /opt/kimi/kimi (the slice-3 launch shape); --version
# needs no credential or network; output is discarded (not guaranteed credential-free).
if svc k5 --property=PrivateNetwork=yes --property=BindReadOnlyPaths="$KIMI_BIN:/opt/kimi/kimi" bash -c "/opt/kimi/kimi --version >/dev/null 2>&1"; then
  ok "bound dispatcher-vetted kimi binary runs under service hardening"
else
  bad "bound kimi binary did not run under service hardening"
fi

echo
if [ "$fails" = 0 ]; then echo "PASS: kimi isolation checks (0 failed) — kimi activation permitted on this host"; exit 0
else echo "FAIL: kimi isolation checks ($fails failed); $PROHIBIT"; exit 1; fi
