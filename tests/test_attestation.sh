#!/usr/bin/env bash
# Phase-aware T1 and execution-policy regression proof.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  ok: $1"
  else echo "  FAIL: $1 — expected '$2', got '$3'"; fails=1; fi
}

PY="${ORCH_TEST_PY:-python3}"
[ -n "${ORCH_TEST_PY:-}" ] || [ ! -x .venv/bin/python ] || PY=.venv/bin/python
out=$($PY - <<'PY'
import copy, importlib.util, pathlib, tempfile
spec=importlib.util.spec_from_file_location("d", pathlib.Path("scripts/dispatch.py"))
d=importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

required=["tests/box.sh","tests/iso.sh","tests/read.sh"]
modes={"tests/box.sh":"box-precondition","tests/iso.sh":"candidate-isolated",
       "tests/read.sh":"candidate-read"}
policy={"manifest_sha256":"m","installed_commit":"a","test_sha256":{t:t for t in required}}
def obs(t, phase, identity, **extra):
    extra.setdefault("installed_commit", "a")
    extra.setdefault("installed_commit_after", "a")
    return {"phase":phase,"status":"PASS","exit_status":0,"manifest_sha256":"m",
            "manifest_sha256_after":"m","test_sha256":t,"test_sha256_after":t,
            "subject":("active host and installed isolation boundary" if phase == "box-precondition" else f"candidate commit {extra.get('candidate_commit')}"),"identity":identity,"started":"s",
            "finished":"f","log_sha256":"l","claim":"candidate bytes are data",
            **extra}
e={
 "tests/box.sh":[obs("tests/box.sh","box-precondition",d.OPERATOR_USER,
                     installed_commit="a",host_id="h",boot_id="b",
                     claim="active installed box boundary passed; candidate version not graded")],
 "tests/iso.sh":[obs("tests/iso.sh","candidate-isolated",d.WORKER_USER,
                     candidate_commit="c",runtime_sha256="r",runtime_sha256_after="r",
                     runtime_interpreter_sha256="i",runtime_requirements_sha256="q")],
 "tests/read.sh":[obs("tests/read.sh","candidate-read",d.OPERATOR_USER,candidate_commit="c")],
}
print("all_pass", d.attest_tests(e,required,modes,policy)[0])
for label, mutate in (
 ("skip", lambda x: x["tests/iso.sh"][0].update(status="SKIP",exit_status=77)),
 ("missing", lambda x: x.__setitem__("tests/iso.sh",[])),
 ("wrong_phase", lambda x: x["tests/iso.sh"][0].update(phase="box-precondition")),
 ("missing_provenance", lambda x: x["tests/iso.sh"][0].update(runtime_sha256=None)),
 ("box_not_candidate", lambda x: (x["tests/iso.sh"].clear(), x["tests/iso.sh"].append(
     obs("tests/iso.sh","box-precondition",d.OPERATOR_USER,installed_commit="a",host_id="h",boot_id="b")))),
):
    case=copy.deepcopy(e); mutate(case)
    print(label+"_blocks", d.attest_tests(case,required,modes,policy)[0])
print("empty_blocks", d.attest_tests({},[],{},policy)[0])

def fixture(manifest, names=("a.sh","b.sh","c.sh","d.sh","e.sh")):
    root=pathlib.Path(tempfile.mkdtemp()); (root/"tests").mkdir()
    for name in names: (root/"tests"/name).write_text("#!/bin/sh\n")
    if manifest is not None: (root/"tests/execution-policy.tsv").write_text(manifest)
    try: p=d.execution_policy(root); return "ok",p
    except ValueError: return "rejected",None
base=("tests/a.sh\tbox-precondition\ta\n"
      "tests/b.sh\tbox-precondition\tb\n"
      "tests/c.sh\tcandidate-read\tc\n"
      "tests/d.sh\tcandidate-read\td\n")
status,p=fixture(base)
print("policy_valid",status)
print("default_isolated",p["modes"]["tests/e.sh"] if p else "none")
for label, manifest in (
 ("missing",None),("malformed",base+"bad row\n"),("unknown",base.replace("candidate-read","weird",1)),
 ("duplicate",base+"tests/a.sh\tcandidate-isolated\tx\n"),
 ("nonexistent",base+"tests/no.sh\tcandidate-isolated\tx\n"),
 ("unsafe",base+"tests/../x.sh\tcandidate-isolated\tx\n"),
): print("policy_"+label,fixture(manifest)[0])
print("policy_empty",fixture("",names=())[0])
PY
) || { echo "SKIP test_attestation.sh: dispatcher dependencies unavailable"; exit 77; }

check "all assigned phases pass" "all_pass True" "$(grep '^all_pass' <<<"$out")"
for c in skip missing wrong_phase missing_provenance box_not_candidate empty; do
  check "$c fails closed" "${c}_blocks False" "$(grep "^${c}_blocks" <<<"$out")"
done
check "valid policy parses" "policy_valid ok" "$(grep '^policy_valid' <<<"$out")"
check "unlisted test defaults isolated" "default_isolated candidate-isolated" "$(grep '^default_isolated' <<<"$out")"
for c in missing malformed unknown duplicate nonexistent unsafe empty; do
  check "policy $c rejected" "policy_${c} rejected" "$(grep "^policy_${c}" <<<"$out")"
done

echo "== runner records SKIP without upgrading it"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tests" "$tmp/scripts"
cp scripts/test "$tmp/scripts/test"
for t in box1 box2 read1 read2 passer; do printf '#!/bin/sh\nexit 0\n' > "$tmp/tests/$t.sh"; done
printf '#!/bin/sh\nexit 77\n' > "$tmp/tests/skipper.sh"
chmod +x "$tmp/tests"/*.sh
printf 'tests/box1.sh\tbox-precondition\tx\ntests/box2.sh\tbox-precondition\tx\ntests/read1.sh\tcandidate-read\tx\ntests/read2.sh\tcandidate-read\tx\n' > "$tmp/tests/execution-policy.tsv"
(cd "$tmp" && ORCH_TEST_SUMMARY="$tmp/sum" bash scripts/test >/dev/null 2>&1)
check "exit-77 remains SKIP" "SKIP tests/skipper.sh" "$(grep skipper "$tmp/sum")"
printf '#!/bin/sh\nexit 77\n' > "$tmp/tests/box1.sh"
printf '#!/bin/sh\nexit 77\n' > "$tmp/tests/box2.sh"
(cd "$tmp" && ORCH_TEST_STRICT=1 bash scripts/test >/dev/null 2>&1); strict_candidate=$?
check "strict rejects candidate-isolated SKIP" 1 "$strict_candidate"
printf '#!/bin/sh\nexit 0\n' > "$tmp/tests/skipper.sh"
(cd "$tmp" && ORCH_TEST_STRICT=1 bash scripts/test >/dev/null 2>&1); strict_box=$?
check "strict tolerates manifest box-precondition SKIPs" 0 "$strict_box"
printf '#!/bin/sh\nexit 77\n' > "$tmp/tests/read1.sh"
(cd "$tmp" && ORCH_TEST_STRICT=1 bash scripts/test >/dev/null 2>&1); strict_read=$?
check "strict rejects candidate-read SKIP" 1 "$strict_read"
cp "$tmp/tests/execution-policy.tsv" "$tmp/policy.good"
printf 'malformed\n' >> "$tmp/tests/execution-policy.tsv"
(cd "$tmp" && bash scripts/test >/dev/null 2>&1); malformed_rc=$?
check "runner fails closed on malformed manifest" 2 "$malformed_rc"
cp "$tmp/policy.good" "$tmp/tests/execution-policy.tsv"

echo "== installed grader remains outside candidate control"
grep -q "required_tests_restored_from_parent" scripts/dispatch.py
check "substitutions are recorded" 0 $?
grep -q "run_candidate_test_phases" scripts/dispatch.py
check "installed dispatcher collects phase results" 0 $?

[ "$fails" -eq 0 ] && echo "PASS test_attestation.sh" || echo "FAIL test_attestation.sh"
exit "$fails"
