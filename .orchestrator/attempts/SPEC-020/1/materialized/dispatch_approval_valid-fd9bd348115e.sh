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
# preflight() reads the spec through read_approved_spec() (single-read; B2 round-2): stub THAT seam
# so this test exercises the approval-schema path, not spec parsing. Returns (bytes, digest, parsed,
# errors).
d.read_approved_spec = lambda sid: (b"id: SPEC-X\n", DIG,
    {"needs_network": False, "depends_on": [], "risk_class": "low",
     "in_scope": ["scripts/**", "tests/**"]}, [])
d.ensure_instance = lambda: {"instance_id": "0" * 32}

def valid_approval(**over):
    a = {"spec_id": "SPEC-X", "spec_digest": DIG, "instance_id": "0" * 32,
         "approver": "val", "approved_scope": ["scripts/**"], "risk_class": "low",
         "timestamp": "2026-07-15T00:00:00Z"}
    a.update(over); return a

def run(approval):
    d.approval_for = lambda dig: approval
    try:
        d.preflight("SPEC-X"); return "ok"
    except SystemExit as e:
        return f"exit{e.code}"

check("valid, bound, in-scope approval -> ok", run(valid_approval()) == "ok")
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
# B1 round-1 review: bind spec_id, refuse broader scope, require risk_class + timestamp
check("approval for a DIFFERENT spec_id -> refused",
      run(valid_approval(spec_id="SPEC-OTHER")) == "exit6")
check("approval approved_scope BROADER than spec in_scope -> refused",
      run(valid_approval(approved_scope=["**"])) == "exit6")
check("approval approved_scope with a glob not in in_scope -> refused",
      run(valid_approval(approved_scope=["scripts/**", "/etc/**"])) == "exit6")
check("approval subset of in_scope (both listed globs) -> ok",
      run(valid_approval(approved_scope=["scripts/**", "tests/**"])) == "ok")
check("approval missing risk_class -> refused", run(valid_approval(risk_class=None)) == "exit6")
check("approval with invalid risk_class -> refused",
      run(valid_approval(risk_class="critical")) == "exit6")
check("approval missing timestamp -> refused", run(valid_approval(timestamp=None)) == "exit6")
# B1 round-2: risk mismatch vs spec, invalid timestamp syntax, unknown field
check("approval risk_class mismatched vs spec (high vs low) -> refused",
      run(valid_approval(risk_class="high")) == "exit6")
check("approval with non-ISO timestamp -> refused",
      run(valid_approval(timestamp="not-a-time")) == "exit6")
check("approval with an unknown field -> refused",
      run({**valid_approval(), "evil": "smuggled"}) == "exit6")

print(f"\n{'PASS' if not fails else 'FAIL'}: B1 approval validation ({len(fails)} failed)")
import sys; sys.exit(1 if fails else 0)
PY
