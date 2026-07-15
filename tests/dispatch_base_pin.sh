#!/usr/bin/env bash
# B3 regression — an approval whose base_branch is not the automation target (ready-for-main) must be
# REFUSED at preflight, before any fetch/worktree/PR, so the reviewed base always equals the landed
# base. Drives the REAL preflight() with stubbed upstream gates. No network, no quota. Box-only skip.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_base_pin.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77
fi

"$PY" - <<'PY'
import importlib.util, pathlib

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# Stub the gates BEFORE the base-pin so we can drive preflight to exactly that point.
d.HALT = pathlib.Path("/nonexistent-halt-marker")
d.validate_spec = lambda sid: ({"needs_network": False, "depends_on": []}, [])
d.spec_digest = lambda sid: "d" * 64
d.ensure_instance = lambda: {"instance_id": "inst-1"}

def run_preflight(base):
    appr = {"spec_digest": "d" * 64, "instance_id": "inst-1"}
    if base is not None:
        appr["base_branch"] = base
    d.approval_for = lambda dig: appr
    try:
        d.preflight("SPEC-X"); return "ok"
    except SystemExit as e:
        return f"exit{e.code}"

check("base absent -> defaults to target, allowed", run_preflight(None) == "ok")
check("explicit ready-for-main -> allowed", run_preflight("ready-for-main") == "ok")
check("base 'main' -> refused exit 6", run_preflight("main") == "exit6")
check("base 'production' -> refused exit 6", run_preflight("production") == "exit6")
check("base '' (empty) -> refused exit 6", run_preflight("") == "exit6")
check("AUTOMATION_BASE constant is ready-for-main", d.AUTOMATION_BASE == "ready-for-main")

# --- persisted-state bypass: the async _run() path never calls preflight() (Codex round-1) --------
import tempfile, json as _json
tmp = pathlib.Path(tempfile.mkdtemp()); d.ATTEMPTS = tmp / "attempts"
def run_via_launch(base):
    att = d.ATTEMPTS / "SPEC-001" / "1"; att.mkdir(parents=True, exist_ok=True)
    lc = {"worktree": str(tmp / "wt"), "base_branch": base, "spec_digest": "d" * 64,
          "base_sha": "0" * 40}
    (att / "launch.json").write_text(_json.dumps(lc))
    try:
        d._run("SPEC-001-1"); return "ran"
    except SystemExit as e:
        return f"exit{e.code}"
    except Exception as e:
        return f"other:{type(e).__name__}"   # got past the base guard (would be a bug)

check("_run with persisted base 'integration' -> refused exit 6 (not ran)",
      run_via_launch("integration") == "exit6")
check("_run with persisted base 'main' -> refused exit 6", run_via_launch("main") == "exit6")

print(f"\n{'PASS' if not fails else 'FAIL'}: B3 base pin ({len(fails)} failed)")
import sys; sys.exit(1 if fails else 0)
PY
