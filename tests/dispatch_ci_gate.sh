#!/usr/bin/env bash
# B7 regression — the provenance-PR merge must gate on an EXACT-name ci=SUCCESS, never merge on a
# failed/pending/missing ci, and never release on a stray "pass"/"fail" substring in gh output.
#
# Drives the REAL decision function (_provenance_merge / _ci_conclusion / _await_ci_success) with a
# scripted fake `d.run`, and asserts whether `gh pr merge` was actually invoked. No network, no gh
# binary, no quota. Same venv-skip contract as the other dispatcher self-tests.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_ci_gate.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test needs the dispatcher venv; CI installs it)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import importlib.util, json, types

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

d.time.sleep = lambda *_a, **_k: None          # no real waiting

# A scripted fake `gh` at the d.run seam: returns a chosen statusCheckRollup for `gh pr view`, and
# records every `gh pr merge` call so we can assert it did or did NOT fire.
class Fake:
    def __init__(self, rollup):
        self.rollup = rollup          # value for statusCheckRollup, or the string 'ERR' to fail the query
        self.merged = False
    def __call__(self, cmd, **kw):
        if cmd[:3] == ["gh", "pr", "view"]:
            if self.rollup == "ERR":
                return types.SimpleNamespace(returncode=1, stdout="", stderr="boom")
            return types.SimpleNamespace(
                returncode=0, stderr="",
                stdout=json.dumps({"statusCheckRollup": self.rollup}))
        if cmd[:3] == ["gh", "pr", "merge"]:
            self.merged = True
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")

def run_merge(rollup):
    """Drive the real _provenance_merge; return (merged?, exit_code_or_None)."""
    fake = Fake(rollup); d.run = fake
    try:
        d._provenance_merge("42"); code = None
    except SystemExit as e:
        code = e.code
    return fake.merged, code

CI_OK   = [{"name": "ci", "conclusion": "SUCCESS"}]
CI_FAIL = [{"name": "ci", "conclusion": "FAILURE"}]
CI_PEND = [{"name": "ci", "status": "IN_PROGRESS", "conclusion": None}]
CI_NONE = [{"name": "lint", "conclusion": "SUCCESS"}]                  # ci absent, only a lint check
CI_STATE_FAIL = [{"context": "ci", "state": "FAILURE"}]               # StatusContext shape
CI_STRAY = [{"name": "lint", "conclusion": "SUCCESS",
             "text": "all tests pass"}]                              # 'pass' substring, but no ci

# --- _ci_conclusion classifies by exact name, fail-closed --------------------------------------
# Drive through the fake so _ci_conclusion runs its real gh-view path:
def concl(rollup):
    d.run = Fake(rollup); return d._ci_conclusion("42")

check("exact ci SUCCESS -> SUCCESS", concl(CI_OK) == "SUCCESS")
check("exact ci FAILURE -> FAILURE", concl(CI_FAIL) == "FAILURE")
check("ci in progress -> PENDING", concl(CI_PEND) == "PENDING")
check("no ci check -> MISSING", concl(CI_NONE) == "MISSING")
check("StatusContext ci FAILURE -> FAILURE", concl(CI_STATE_FAIL) == "FAILURE")
check("failed gh query -> PENDING (never SUCCESS)", concl("ERR") == "PENDING")
check("stray 'pass' text with no ci check -> MISSING, not SUCCESS", concl(CI_STRAY) == "MISSING")

# --- _provenance_merge: merge ONLY on ci=SUCCESS -----------------------------------------------
merged, code = run_merge(CI_OK)
check("ci green -> merge invoked, no exit", merged and code is None)

merged, code = run_merge(CI_FAIL)
check("ci FAILED -> NO merge, dies exit 20", (not merged) and code == 20)

merged, code = run_merge(CI_NONE)
check("ci MISSING (timeout) -> NO merge, dies exit 20", (not merged) and code == 20)

merged, code = run_merge("ERR")
check("gh query error (timeout) -> NO merge, dies exit 20", (not merged) and code == 20)

print(f"\n{'PASS' if not fails else 'FAIL'}: B7 provenance ci-gate ({len(fails)} failed)")
import sys; sys.exit(1 if fails else 0)
PY
