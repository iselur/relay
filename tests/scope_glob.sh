#!/usr/bin/env bash
# The scope gate is the ONLY structural defence against a worker writing outside its approved paths
# (every other defence is a model being asked nicely). fnmatch's `*` matches `/`, so an approved
# scope of `scripts/lib/*.sh` silently permitted `scripts/lib/nested/evil.sh`.
# These assertions FAIL against the pre-fix dispatcher and PASS after.
set -uo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP scope_glob.sh: .venv/pyyaml/jsonschema absent (box-only)"
  exit 77   # did NOT run — never a pass (T1)
fi

"$PY" - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

cases = [
    # (path, approved_scope, allowed?, label)
    ("scripts/lib/util.sh",        ["scripts/lib/*.sh"],    True,  "direct child matches"),
    ("scripts/lib/nested/evil.sh", ["scripts/lib/*.sh"],    False, "* must NOT cross /"),
    ("tests/deep/a/b/pwn.sh",      ["tests/*.sh"],          False, "* must NOT cross many /"),
    ("scripts/lib/nested/ok.sh",   ["scripts/lib/**"],      True,  "** stays recursive"),
    ("scripts/lib",                ["scripts/lib/**"],      True,  "** matches the root itself"),
    ("scripts/dispatch.py",        ["scripts/dispatch.py"], True,  "literal path matches"),
    ("scripts/evil.py",            ["scripts/dispatch.py"], False, "literal path is literal"),
    ("a/b/c.sh",                   ["a/**/c.sh"],           True,  "** mid-pattern"),
    ("a/c.sh",                     ["a/**/c.sh"],           True,  "** matches zero dirs"),
    ("a/b.sh",                     [],                      False, "empty scope allows nothing"),
]
fails = 0
for path, scope, want, label in cases:
    got = d._match_glob(path, scope)
    if got == want:
        print(f"  ok: {label}")
    else:
        print(f"  FAIL: {label} — {path} vs {scope} gave {got}, want {want}")
        fails += 1
sys.exit(1 if fails else 0)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "PASS scope_glob.sh" || echo "FAIL scope_glob.sh"
exit "$rc"
