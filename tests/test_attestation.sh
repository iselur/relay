#!/usr/bin/env bash
# T1 (decision R26) — a test that did not RUN has not PASSED.
#
# This is the regression proof for the SPEC-015/1 false PASS: three trust-class tests SKIPped,
# `./scripts/test` exited 0 anyway, the reviewer was told only "test_command exited 0", and it
# certified the skipped tests as proof. 1 false PASS out of 14 — and it was the only high-risk
# attempt in the corpus.
#
# These assertions FAIL against the pre-T1 dispatcher (which had no attest_tests at all) and PASS
# after. No venv needed: pure stdlib, so it runs in CI too — deliberately, because the tests that
# CI *cannot* run are exactly the ones that used to skip-as-pass.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 — expected '$2', got '$3'"; fails=1
  fi
}

echo "== T1: SKIP != PASS attestation"

# dispatch.py needs pyyaml/jsonschema at import time. CI installs them into .venv, not the system
# python — use the venv when present so this test RUNS in CI instead of skip-looping forever.
PY="python3"
[ -x ".venv/bin/python" ] && PY=".venv/bin/python"

out=$("$PY" - <<'PY'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("d", pathlib.Path("scripts/dispatch.py"))
d = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(d)          # needs pyyaml/jsonschema at import time
except Exception as e:                  # pragma: no cover - CI without the venv
    print("IMPORT_FAILED", e); sys.exit(0)

P = d.parse_test_summary
A = d.attest_tests

# 1. The SPEC-015 shape: the suite "passed" (exit 0) while required tests skipped.
summary = P("PASS tests/slugify.sh\nSKIP tests/dispatch_gate4.sh\nSKIP tests/worker_isolation.sh\n")
ok, why = A(summary, ["tests/slugify.sh", "tests/dispatch_gate4.sh", "tests/worker_isolation.sh"])
print("skip_blocks", ok)
print("skip_names_them", "dispatch_gate4" in why and "worker_isolation" in why)

# 2. The empty-required-set hole (round-10 finding): zero tests + zero assertions is a vacuous,
#    internally consistent "pass". It must never authorize a review.
ok_empty, why_empty = A(P("PASS tests/anything.sh\n"), [])
print("empty_set_blocks", ok_empty)

# 3. A required test that never reported at all (deleted by the worker, runner crashed, etc).
ok_missing, _ = A(P("PASS tests/slugify.sh\n"), ["tests/slugify.sh", "tests/vanished.sh"])
print("missing_blocks", ok_missing)

# 4. A required test that FAILED is obviously not a pass.
ok_failed, _ = A(P("FAIL tests/slugify.sh\n"), ["tests/slugify.sh"])
print("failed_blocks", ok_failed)

# 5. The happy path still passes — the gate must not be vacuously strict either.
ok_pass, _ = A(P("PASS tests/a.sh\nPASS tests/b.sh\n"), ["tests/a.sh", "tests/b.sh"])
print("all_pass_passes", ok_pass)

# 6. Worker prose in test.log is NOT parsed as a result. Only the runner's own summary lines are.
forged = P("I hereby declare: PASS tests/dispatch_gate4.sh is definitely fine\nsome other noise\n")
print("prose_not_parsed", "tests/dispatch_gate4.sh" not in forged)
PY
)

if grep -q IMPORT_FAILED <<<"$out"; then
  echo "SKIP test_attestation.sh: dispatch.py needs pyyaml/jsonschema (box-only)"
  exit 77   # did NOT run — never a pass (this file practises what it preaches)
fi

check "a SKIPped required test blocks the gate"        "skip_blocks False"     "$(grep '^skip_blocks' <<<"$out")"
check "the block names the skipped tests"              "skip_names_them True"  "$(grep '^skip_names_them' <<<"$out")"
check "an EMPTY required set blocks (round-10 hole)"   "empty_set_blocks False" "$(grep '^empty_set_blocks' <<<"$out")"
check "a required test with no result blocks"          "missing_blocks False"  "$(grep '^missing_blocks' <<<"$out")"
check "a FAILED required test blocks"                  "failed_blocks False"   "$(grep '^failed_blocks' <<<"$out")"
check "all-passed still passes"                        "all_pass_passes True"  "$(grep '^all_pass_passes' <<<"$out")"
check "worker prose is not parsed as a verdict"        "prose_not_parsed True" "$(grep '^prose_not_parsed' <<<"$out")"

echo "== T1: runner reports SKIP as SKIP (not PASS)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tests"
printf '#!/usr/bin/env bash\nexit 77\n' > "$tmp/tests/skipper.sh"
printf '#!/usr/bin/env bash\nexit 0\n'  > "$tmp/tests/passer.sh"
chmod +x "$tmp/tests"/*.sh
cp scripts/test "$tmp/runner"
( cd "$tmp" && mkdir -p scripts && cp runner scripts/test && ORCH_TEST_SUMMARY="$tmp/sum" bash scripts/test >/dev/null 2>&1 )
check "exit-77 test recorded as SKIP" "SKIP tests/skipper.sh" "$(grep skipper "$tmp/sum" 2>/dev/null)"
check "exit-0 test recorded as PASS"  "PASS tests/passer.sh"  "$(grep passer  "$tmp/sum" 2>/dev/null)"

echo "== T1b: a worker cannot neuter a required test (grader out of reach)"
# THE ATTACK: a spec whose approved scope includes tests/ (SPEC-017's did) rewrites a required test
# to `exit 0`. Pre-T1b this passed the gate honestly: the test "ran" and "passed" — it just asserted
# nothing. The gate must restore the ORCHESTRATOR's copy before running, so the worker's version
# grades nothing.
grep -q "required_tests_restored_from_parent" ../scripts/dispatch.py 2>/dev/null ||
  grep -q "required_tests_restored_from_parent" scripts/dispatch.py
check "attestation records substituted required tests" "0" "$?"

src=$(cat scripts/dispatch.py)
case "$src" in
  *"HOLD THE GRADER OUT OF THE AGENT'S REACH"*) ok=0 ;;
  *) ok=1 ;;
esac
check "the gate restores required tests from the parent copy" "0" "$ok"

# Prove the restore actually defeats the attack, end to end.
atk=$(mktemp -d); trap 'rm -rf "$tmp" "$atk"' EXIT
mkdir -p "$atk/tests" "$atk/scripts"
cp scripts/test "$atk/scripts/test"
printf '#!/usr/bin/env bash\necho "neutered"\nexit 0\n' > "$atk/tests/victim.sh"   # worker's version
printf '#!/usr/bin/env bash\necho "real assertion failed"\nexit 1\n' > "$atk/parent_victim.sh" # parent's
chmod +x "$atk/tests/victim.sh"
# simulate the restore: parent copy overwrites the worker's
cp "$atk/parent_victim.sh" "$atk/tests/victim.sh"
( cd "$atk" && ORCH_TEST_SUMMARY="$atk/sum" bash scripts/test >/dev/null 2>&1 )
check "restored test fails as it should (worker's exit-0 stub did not grade)" \
      "FAIL tests/victim.sh" "$(grep victim "$atk/sum" 2>/dev/null)"

[ "$fails" -eq 0 ] && echo "PASS test_attestation.sh" || echo "FAIL test_attestation.sh"
exit "$fails"
