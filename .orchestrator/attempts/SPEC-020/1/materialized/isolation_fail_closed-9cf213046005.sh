#!/usr/bin/env bash
# T2 (decision R26) — worker isolation FAILS CLOSED.
#
# The old behaviour: if D5 isolation was unavailable (fresh box, CI, broken sudo), the dispatcher
# SILENTLY fell back to running worker-authored code as the operator — with the operator's home,
# credentials and network. It recorded isolation:false and carried on. That is the one catastrophe
# that is actually plausible on a single-tenant box, and it was the DEFAULT whenever D5 was absent.
#
# Now: refuse, before the slot claim, before the attempt directory, before the worktree, before any
# worker code. Break-glass is ORCH_ALLOW_UNISOLATED=1 — an env var you type knowingly, recorded in
# the evidence. No token, no sudoers, no ledger (that machinery defends the box from its owner).
#
# These assertions FAIL against the pre-T2 dispatcher (which launched happily) and PASS after.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fails=1; }

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP isolation_fail_closed.sh: .venv/pyyaml/jsonschema absent (box-only)"
  exit 77   # did NOT run — never a pass (T1)
fi

echo "== T2: refusal is fail-closed, and lands before any durable state"

eval "$("$PY" - <<'PY'
import pathlib
src = pathlib.Path("scripts/dispatch.py").read_text()
launch = src.split("def cmd_launch", 1)[1]
# ORDERING is the whole point: the refusal must land BEFORE claim_slot (the slot + the durable
# 'launching' record) and BEFORE the attempt directory. A refusal after either leaves state behind
# and can consume a slot. The FROZEN decision must then be passed down, never recomputed — a second
# isolation_available() call on the launch path IS the downgrade hole.
checks = {
 "has_err_class": "ERR_NO_ISOLATION" in src and "isolation_unavailable" in src,
 "refusal_before_preflight": 0 <= launch.find("REFUSING to launch") < launch.find("preflight("),
 "refusal_before_claim_slot": 0 <= launch.find("REFUSING to launch") < launch.find("claim_slot("),
 "refusal_before_attempt_dir": 0 <= launch.find("REFUSING to launch") < launch.find(".mkdir(parents=True"),
 "worktree_root_takes_decision": "def worktree_root(iso: bool | None = None)" in src,
 "launch_passes_frozen_decision": "worktree_root(iso)" in launch,
 "breakglass_is_explicit": 'os.environ.get("ORCH_ALLOW_UNISOLATED") == "1"' in src,
 "exposure_recorded": '"exposure_accepted"' in src,
 "worker_phase_refuses_untrusted_record": 'not lc.get("exposure_accepted")' in src,
}
for k, v in checks.items():
    print(f'{k}={1 if v else 0}')
PY
)"

for c in has_err_class refusal_before_preflight refusal_before_claim_slot refusal_before_attempt_dir \
         worktree_root_takes_decision launch_passes_frozen_decision \
         breakglass_is_explicit exposure_recorded worker_phase_refuses_untrusted_record; do
  if [ "${!c}" = "1" ]; then ok "$c"; else bad "$c"; fi
done

echo "== T2: candidate path-safety validation runs in the isolated test phase"
if "$PY" - <<'PY'
import importlib.util, os, pathlib, tempfile
spec = importlib.util.spec_from_file_location("d", pathlib.Path("scripts/dispatch.py"))
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)
root = pathlib.Path(tempfile.mkdtemp())
(root / "ok.txt").write_text("ok")
os.symlink("ok.txt", root / "link")
os.mkfifo(root / "pipe")
bad = d.validate_worktree_safe(root)
raise SystemExit(0 if set(bad) == {"link", "pipe"} else 1)
PY
then ok "validate_worktree_safe rejects candidate symlinks and FIFOs"
else bad "validate_worktree_safe missed a candidate special file"
fi

echo "== T2: live refusal (only meaningful where D5 is genuinely absent)"
if "$PY" -c 'import importlib.util,pathlib;s=importlib.util.spec_from_file_location("d",pathlib.Path("scripts/dispatch.py"));m=importlib.util.module_from_spec(s);s.loader.exec_module(m);import sys;sys.exit(0 if m.isolation_available() else 1)'; then
  echo "  note: D5 IS available here, so a live refusal cannot be provoked without breaking the box."
  echo "        The ordering assertions above are what prove the gate; the live drill runs on a"
  echo "        D5-less host (CI) where isolation_available() is false."
else
  before=$(ls -d .orchestrator/attempts/*/ 2>/dev/null | wc -l)
  out=$(./scripts/dispatch launch SPEC-001 2>&1); rc=$?
  after=$(ls -d .orchestrator/attempts/*/ 2>/dev/null | wc -l)
  [ "$rc" -ne 0 ]                        && ok "refuses to launch without D5" || bad "launched without D5!"
  grep -q "REFUSING to launch" <<<"$out" && ok "refusal is loud"              || bad "refusal not explained"
  [ "$before" = "$after" ]               && ok "no attempt directory created" || bad "left durable state behind"
fi

[ "$fails" -eq 0 ] && echo "PASS isolation_fail_closed.sh" || echo "FAIL isolation_fail_closed.sh"
exit "$fails"
