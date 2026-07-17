#!/usr/bin/env bash
# R88 — advisory scope-overlap warning at launch. _warn_scope_overlaps() prints a stderr hint
# when another PENDING spec's in_scope could touch the same paths; it must NEVER change launch
# behavior: no exception, no exit, no output beyond stderr. This exercises the REAL function in
# scripts/dispatch.py. Same harness contract as dispatch_parallel.sh: dispatch.py needs the box
# venv (pyyaml/jsonschema absent on CI), so run for real on the box and SKIP LOUDLY in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_scope_warn.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test needs the dispatcher venv; CI installs it)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import contextlib, importlib.util, io, json, pathlib, sys, tempfile, yaml

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

d.SPECS = pathlib.Path(tempfile.mkdtemp())   # isolate from real specs/
d.STATE = pathlib.Path(tempfile.mkdtemp())   # isolate from real .orchestrator/state

def write_spec(sid, in_scope, depends_on=None):
    body = {"id": sid, "title": "t", "risk_class": "default", "objective": "o",
            "in_scope": in_scope, "acceptance_criteria": ["a"], "test_command": "true"}
    if depends_on: body["depends_on"] = depends_on
    (d.SPECS / f"{sid}.yaml").write_text(yaml.dump(body))

def warnings(sid, in_scope, depends_on=()):
    """Run the advisory; return stderr text. Any exception/exit is a test failure by itself."""
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        d._warn_scope_overlaps(sid, list(in_scope), list(depends_on))
    return err.getvalue()

# --- warning fires ----------------------------------------------------------------------------
write_spec("SPEC-901", ["scripts/dispatch.py"])
check("the launching spec never warns about itself (only own spec on disk)",
      warnings("SPEC-901", ["scripts/dispatch.py"]) == "")
w = warnings("SPEC-902", ["scripts/dispatch.py"])
check("identical glob warns and names the spec", "SPEC-901" in w and "depends_on" in w)

write_spec("SPEC-903", ["scripts/**"])
check("dir/** covering a literal warns", "SPEC-903" in warnings("SPEC-902", ["scripts/dispatch.py"]))
check("literal covered by other's wildcard warns", "SPEC-903" in warnings("SPEC-902", ["scripts/new_module.py"]))
write_spec("SPEC-906", ["scripts/*.py"])   # segment wildcard: neither identical nor dir/** — the _match_glob fallback
check("segment wildcard vs literal warns (generic fallback)",
      "SPEC-906" in warnings("SPEC-902", ["scripts/new_module.py"]))
(d.SPECS / "SPEC-906.yaml").unlink()

# --- no warning -------------------------------------------------------------------------------
check("disjoint scopes stay silent", warnings("SPEC-902", ["docs/**"]) == "")
check("depends_on (ours) suppresses", "SPEC-901" not in warnings("SPEC-902", ["scripts/dispatch.py"], ["SPEC-901"]))
write_spec("SPEC-904", ["scripts/dispatch.py"], depends_on=["SPEC-902"])
check("depends_on (theirs) suppresses", "SPEC-904" not in warnings("SPEC-902", ["scripts/dispatch.py"]))

for done in ("passed_pr_opened", "merged"):
    (d.STATE / "SPEC-901.json").write_text(json.dumps({"spec_id": "SPEC-901", "status": done}))
    check(f"completed state {done!r} suppresses", "SPEC-901" not in warnings("SPEC-902", ["scripts/dispatch.py"]))
(d.STATE / "SPEC-901.json").unlink()

# --- advice never breaks a launch -------------------------------------------------------------
(d.SPECS / "SPEC-905.yaml").write_text("{ [ : not yaml")
check("malformed candidate YAML skipped silently", "SPEC-905" not in warnings("SPEC-902", ["scripts/dispatch.py"]))
(d.STATE / "SPEC-901.json").write_text("{corrupt json")
check("corrupt candidate state JSON skipped silently",
      "SPEC-901" not in warnings("SPEC-902", ["scripts/dispatch.py"]))
(d.STATE / "SPEC-901.json").unlink()

out = io.StringIO()
with contextlib.redirect_stdout(out):
    w = warnings("SPEC-902", ["scripts/dispatch.py"])
check("warning goes to stderr only, stdout untouched", out.getvalue() == "" and "SPEC-901" in w)

class BrokenStderr(io.TextIOBase):
    def write(self, s): raise OSError("stderr closed")
try:
    with contextlib.redirect_stderr(BrokenStderr()):
        d._warn_scope_overlaps("SPEC-902", ["scripts/dispatch.py"], [])
    broke = False
except BaseException:
    broke = True
check("broken stderr never escapes (advice must not break a launch)", not broke)

print(f"\n{'PASS' if not fails else 'FAIL'}: advisory scope-overlap warning ({len(fails)} failed)")
sys.exit(1 if fails else 0)
PY
