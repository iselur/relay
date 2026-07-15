#!/usr/bin/env bash
# B1 regression — the spec approval artifact must be schema-validated (not trusted by digest+instance
# equality alone), and the per-attempt high-risk approval must be validated + bound, not accepted by
# mere existence. This file drives the main preflight() approval-schema path; the per-attempt path is
# covered in tests/dispatch_gate4.sh. Box-only skip contract.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_approval_valid.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
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

DIG = "a" * 64
d.HALT = pathlib.Path("/nonexistent-halt-marker")
d.validate_spec = lambda sid: ({"needs_network": False, "depends_on": []}, [])
d.spec_digest = lambda sid: DIG
d.ensure_instance = lambda: {"instance_id": "0" * 32}

def valid_approval(**over):
    a = {"spec_id": "SPEC-X", "spec_digest": DIG, "instance_id": "0" * 32,
         "approver": "val", "approved_scope": ["scripts/**"]}
    a.update(over); return a

def run(approval):
    d.approval_for = lambda dig: approval
    try:
        d.preflight("SPEC-X"); return "ok"
    except SystemExit as e:
        return f"exit{e.code}"

check("valid, bound approval -> ok", run(valid_approval()) == "ok")
check("empty {} approval -> refused exit 6", run({}) == "exit6")
check("approval missing approved_scope -> refused", run(valid_approval(approved_scope=None)) != "ok")
check("approval with empty approved_scope [] -> refused",
      run({**valid_approval(), "approved_scope": []}) == "exit6")
check("approval with malformed spec_digest -> refused",
      run(valid_approval(spec_digest="xyz")) == "exit6")
check("approval with malformed instance_id -> refused",
      run(valid_approval(instance_id="short")) == "exit6")
check("approval bound to a different instance -> refused",
      run(valid_approval(instance_id="1" * 32)) == "exit6")
check("approval with a non-matching spec_digest value -> refused",
      run(valid_approval(spec_digest="b" * 64)) == "exit6")

print(f"\n{'PASS' if not fails else 'FAIL'}: B1 approval validation ({len(fails)} failed)")
import sys; sys.exit(1 if fails else 0)
PY
