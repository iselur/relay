#!/usr/bin/env bash
# Kimi ACP transport proof — PLAN-009 slice 1 earliest-proof gate (operator, run on the host).
#
# Proves, through the EXACT production hardened envelope (dispatch.isolated_cmd — the same
# sudo systemd-run --pipe command the worker launch path executes), that:
#   --smoke           a full ACP session works end to end: initialize → session/new →
#                     set_model to the frozen kimi-k3 alias (config_option_update read-back
#                     asserted as evidence) → set_mode yolo → session/prompt → end_turn, AND the worker
#                     actually wrote a file inside its confined workdir (yolo self-approval
#                     works under the hardening).
#   --prompt-bytes N  a prompt of ≥N bytes travels inside a stdin frame — never argv, so no
#                     MAX_ARG_STRLEN ceiling (R97) — and the session completes without a
#                     write-side pipe stall (PLAN-009 N4). The gate default exceeds 131072.
# A negative control always runs: a bogus modelId must fail closed before any prompt.
#
# Contract: exit 0 = the transport proof holds. 77 = did not run (never a pass). Anything
# else disproves the approach — stop before PR 2 (PLAN-009); do not add a -p fallback.
set -uo pipefail
cd "$(dirname "$0")/.."

WORKER=codex-worker
WORKROOT=/srv/codexwork
STOP="the ACP transport is NOT proven"

DO_SMOKE=0
BIG_BYTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) DO_SMOKE=1; shift ;;
    --prompt-bytes) BIG_BYTES="$2"; shift 2 ;;
    *) echo "usage: $0 [--smoke] [--prompt-bytes N]"; exit 2 ;;
  esac
done
[ "$DO_SMOKE" = 1 ] || [ -n "$BIG_BYTES" ] || { echo "usage: $0 [--smoke] [--prompt-bytes N]"; exit 2; }

# ---- preconditions: 77 = did not run (never a pass) ------------------------------------------
if ! id "$WORKER" >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
  echo "SKIP: codex-worker user or passwordless sudo absent (run scripts/setup-worker-user.sh); $STOP"; exit 77
fi
OPERATOR="${ORCH_OPERATOR_USER:-$(id -un)}"
[ "$OPERATOR" = root ] && { echo "SKIP: operator resolved to root; run as the operator or set ORCH_OPERATOR_USER; $STOP"; exit 77; }
sudo test -f "/home/$WORKER/.kimi-code/credentials/kimi-code.json" || { echo "SKIP: worker kimi state not provisioned (run scripts/setup-worker-user.sh); $STOP"; exit 77; }
[ -d "$WORKROOT" ] || { echo "SKIP: $WORKROOT absent (run scripts/setup-worker-user.sh); $STOP"; exit 77; }
PY="${ORCH_TEST_PY:-.venv/bin/python}"
[ -x "$PY" ] || { echo "SKIP: no python at $PY; $STOP"; exit 77; }
if sudo -n pgrep -u "$WORKER" >/dev/null 2>&1; then
  echo "SKIP: $WORKER has running processes — stop dispatch and re-run; $STOP"; exit 77
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RAWROOT="$PWD/.orchestrator/attempts/ACP-CHECK-$TS"
WORKDIR="$WORKROOT/acp-check-$TS"
mkdir -p "$RAWROOT"
sudo mkdir -p "$WORKDIR" && sudo chown "$WORKER:$WORKER" "$WORKDIR" && sudo chmod 700 "$WORKDIR" \
  || { echo "SKIP: cannot prepare worker workdir $WORKDIR; $STOP"; exit 77; }
trap 'sudo rm -rf "$WORKDIR"' EXIT

fails=0
ok(){ echo "ok   $*"; }
bad(){ echo "FAIL $*"; fails=$((fails+1)); }

run_case(){ # $1 case, extra args appended; prints driver output, returns its exit
  local case="$1"; shift
  ORCH_OPERATOR_USER="$OPERATOR" "$PY" scripts/kimi_acp.py --case "$case" \
    --workdir "$WORKDIR" --raw-dir "$RAWROOT/$case" "$@" | tee "$RAWROOT/$case.out"
  return "${PIPESTATUS[0]}"
}

echo "== negative control: bogus modelId must fail closed before any prompt"
if run_case negative; then ok "bogus model refused (jsonrpc_error, nonzero effective status)"
else bad "negative control: bogus modelId did not fail closed"; fi

if [ "$DO_SMOKE" = 1 ]; then
  echo "== smoke: full ACP session + worker file write under the hardened envelope"
  if run_case smoke; then
    TAG="$(grep -o 'ACP-SMOKE-[0-9]*' "$RAWROOT/smoke.out" | head -1)"
    GOT="$(sudo cat "$WORKDIR/acp-smoke.txt" 2>/dev/null)"
    if [ -n "$TAG" ] && [ "$GOT" = "$TAG" ]; then ok "worker wrote acp-smoke.txt with exact tag $TAG"
    else bad "smoke session passed but file check failed (tag='$TAG' file='$GOT')"; fi
  else bad "smoke session failed"; fi
fi

if [ -n "$BIG_BYTES" ]; then
  echo "== big: ≥$BIG_BYTES-byte prompt via stdin frame, no argv, no write stall"
  if run_case big --prompt-bytes "$BIG_BYTES"; then ok "$BIG_BYTES-byte prompt completed via ACP"
  else bad "big-prompt session failed"; fi
fi

EVID=".orchestrator/evidence/kimi-acp-hardened-proof.md"
mkdir -p .orchestrator/evidence
{
  echo "# Kimi ACP hardened transport proof (PLAN-009 slice 1)"
  echo
  echo "- date: $TS  commit: $(git rev-parse --short HEAD 2>/dev/null || echo n/a)"
  echo "- envelope: dispatch.isolated_cmd (production command builder), stdio attached"
  echo "- cases run: negative$( [ "$DO_SMOKE" = 1 ] && echo -n ', smoke' )$( [ -n "$BIG_BYTES" ] && echo -n ", big($BIG_BYTES bytes)" )  failures: $fails"
  echo "- raw frames + argv + worker stderr: $RAWROOT"
  echo
  for c in negative smoke big; do
    [ -f "$RAWROOT/$c.out" ] || continue
    echo "## $c"; echo '```'; cat "$RAWROOT/$c.out"; echo '```'
  done
} > "$EVID"
echo "evidence: $EVID"

echo
if [ "$fails" = 0 ]; then echo "PASS: kimi ACP transport proof (0 failed)"; exit 0
else echo "FAIL: kimi ACP transport proof ($fails failed); $STOP"; exit 1; fi
