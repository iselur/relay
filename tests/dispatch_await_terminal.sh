#!/usr/bin/env bash
# R82 regression: every _run_pipeline/_grade refusal path must record a TERMINAL status, so
# `dispatch await` resolves it immediately instead of polling out its 8h max_wait. Three
# _run_pipeline paths (unaccepted-exposure refusal, both deadline-exhausted-before-worker
# refusals) recorded failed_launch — a status in neither TERMINAL nor LIVE.
#
# Exercises the REAL functions in scripts/dispatch.py against synthetic state — no workers
# launched. Same venv-skip contract as tests/dispatch_fail_closed.sh: no usable
# venv; SKIP LOUDLY there.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_await_terminal.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test needs the dispatcher venv; CI installs it)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import contextlib, importlib.util, io, json, pathlib, re, sys, tempfile, time

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# --- 1. Static sweep: every literal status handed to finish() is TERMINAL ------------------
# All finish() call sites pass a string literal first argument (verified: no bare
# `finish(<expr>` remains), so this sweep covers every refusal/result path, current and future.
src = pathlib.Path("scripts/dispatch.py").read_text()
statuses = set(re.findall(r'finish\("([a-z_]+)"', src))
check("finish() statuses found", bool(statuses))
for s in sorted(statuses):
    check(f"finish status {s!r} is TERMINAL", s in d.TERMINAL)
check("failed_launch is no longer written anywhere", "failed_launch" not in statuses)

tmp = pathlib.Path(tempfile.mkdtemp())
d.STATE = tmp / "state"; d.STATE.mkdir(parents=True)
d.ATTEMPTS = tmp / "attempts"

# --- 2. Drive the fixed refusal paths through the real _run_pipeline -----------------------
class Finished(SystemExit):
    def __init__(self, status, err_class):
        super().__init__(1)
        self.status, self.err_class = status, err_class

def run_pipeline(lc):
    raw = tmp / "raw"; raw.mkdir(exist_ok=True)
    def finish(status, err_class, **extra):  # the real finish sys.exit()s; mimic that
        raise Finished(status, err_class)
    d.worker_prompt_text = lambda att, lc, n: "prompt"  # spec snapshot not under test
    try:
        d._run_pipeline("SPEC-900-1", "SPEC-900", 1, tmp, lc, tmp, raw, finish)
    except Finished as f:
        return f.status, f.err_class
    return None, None

# Path 1: isolation:false without a recorded operator exposure acceptance (T2 refusal).
status, err = run_pipeline({})
check("exposure refusal records error_launch", status == "error_launch")
check("exposure refusal keeps ERR_NO_ISOLATION", err == d.ERR_NO_ISOLATION)
check("exposure refusal status is TERMINAL", status in d.TERMINAL)

# Path 2: attempt deadline exhausted before the worker phase starts (B6, unisolated branch).
# The isolated branch's twin refusal writes the identical status; the static sweep covers it.
status, err = run_pipeline({"exposure_accepted": True, "deadline_ts": time.time() - 60})
check("exhausted-deadline refusal records error_launch", status == "error_launch")
check("exhausted-deadline refusal keeps ERR_TIMEOUT", err == d.ERR_TIMEOUT)
check("exhausted-deadline refusal status is TERMINAL", status in d.TERMINAL)

# --- 3. `dispatch await` resolves such an attempt immediately, not after max_wait ----------
d.write_state("SPEC-900", {"attempt_id": "SPEC-900-1", "spec_id": "SPEC-900", "attempt": 1,
                           "status": "error_launch", "error_class": d.ERR_TIMEOUT,
                           "detail": "synthetic refusal record"})
buf = io.StringIO()
t0 = time.monotonic()
code = None
with contextlib.redirect_stdout(buf):
    try:
        d.cmd_await("SPEC-900-1", interval=5, max_wait=20)
    except SystemExit as e:
        code = e.code
elapsed = time.monotonic() - t0
out = json.loads(buf.getvalue())
check("await exits 1 for the refusal", code == 1)
check("await reports error_launch", out.get("status") == "error_launch")
check("await resolves before the first poll interval", elapsed < 2)

print(f"{'FAIL' if fails else 'PASS'} dispatch_await_terminal ({len(fails)} failures)")
sys.exit(1 if fails else 0)
PY
