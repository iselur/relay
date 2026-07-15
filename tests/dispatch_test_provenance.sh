#!/usr/bin/env bash
# B4 regression test — the required test suite, its manifest, and every required test's bytes
# must be derived from the PINNED GIT COMMIT tree, never the filesystem working tree, and grading
# must REFUSE outright if the working tree has drifted from that commit for any grader-relevant
# path (tests/, tests/execution-policy.tsv, scripts/test).
#
# Before this fix: execution_policy() globbed tests/*.sh and sha256'd them straight off disk, then
# the caller separately stamped the result with `git rev-parse HEAD` — with no comparison between
# the two. A dirty, deleted, replaced, or untracked tests/*.sh file could silently redefine what
# got graded while the attestation still claimed it was HEAD (codex-audit-2026-07-15, finding B4 /
# verification H4).
#
# Exercises the REAL functions in scripts/dispatch.py (execution_policy, grader_drift,
# required_tests, git_show_bytes, git_ls_tree_sh, run_candidate_test_phases) against a REAL temp
# git repo — no workers launched, no quota burned. Same box-only skip contract as
# tests/dispatch_gate4.sh: dispatch.py imports pyyaml + jsonschema from the box venv (.venv),
# which is not present on the CI runner. SKIP LOUDLY there, run for real here.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_test_provenance.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import hashlib, importlib.util, os, pathlib, subprocess, tempfile, sys

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

def sh(*a, cwd):
    subprocess.run(a, cwd=str(cwd), check=True, capture_output=True)

# --- build a real git repo that looks like the grader's view of the installed repo ------------
tmp = pathlib.Path(tempfile.mkdtemp())
work = tmp / "work"
sh("git", "init", "-qb", "main", str(work), cwd=tmp)
sh("git", "config", "user.email", "t@t", cwd=work)
sh("git", "config", "user.name", "t", cwd=work)
(work / "tests").mkdir()
(work / "scripts").mkdir()
(work / "tests" / "a.sh").write_text("#!/bin/sh\nexit 0\n")
(work / "tests" / "b.sh").write_text("#!/bin/sh\nexit 0\n")
(work / "tests" / "execution-policy.tsv").write_text(
    "tests/a.sh\tcandidate-read\ta reads only\n"
    "tests/b.sh\tcandidate-isolated\tb runs isolated\n")
(work / "scripts" / "test").write_text("#!/bin/sh\necho runner\n")
# trusted_test_runtime() unconditionally hashes ROOT/scripts/requirements.txt (even when it is
# about to return None/False for an unrelated reason) — give it something to read so a box that
# happens to have a real /opt test runtime provisioned doesn't crash this fixture with ENOENT.
(work / "scripts" / "requirements.txt").write_text("dummy\n")
sh("git", "add", "-A", cwd=work)
sh("git", "commit", "-qm", "base", cwd=work)
commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(work),
                        capture_output=True, text=True).stdout.strip()

a_bytes = (work / "tests" / "a.sh").read_bytes()
b_bytes = (work / "tests" / "b.sh").read_bytes()
a_sha = hashlib.sha256(a_bytes).hexdigest()
b_sha = hashlib.sha256(b_bytes).hexdigest()

# required_tests() and run_candidate_test_phases() hardcode the module-global ROOT/EXECUTION_POLICY
# (production always IS the real repo, so they never need a root param). Redirect both at this
# fixture repo for the whole test — exactly like dispatch_gate4.sh redirects d.worktree_root/
# d.git/d.run for its regression-gate section — then restore in `finally`. Patched from the start
# (rather than partway through) so every execution_policy() call below sees a consistent
# root-vs-ROOT relationship — the "authority" field flips "installed"/"candidate" on that
# comparison and must not spuriously differ between the baseline and later re-checks.
_orig_root, _orig_policy_path = d.ROOT, d.EXECUTION_POLICY
d.ROOT = work
d.EXECUTION_POLICY = work / "tests" / "execution-policy.tsv"
try:
    # --- clean tree: grades normally -----------------------------------------------------------
    check("clean tree: grader_drift is empty", d.grader_drift(commit, work) == [])
    baseline = d.execution_policy(work, commit)
    check("clean tree: required set is exactly the committed tests",
          baseline["required"] == ["tests/a.sh", "tests/b.sh"])
    check("clean tree: hashes match the committed blobs",
          baseline["test_sha256"]["tests/a.sh"] == a_sha
          and baseline["test_sha256"]["tests/b.sh"] == b_sha)
    check("clean tree: git_show_bytes reads the exact committed content",
          d.git_show_bytes(commit, "tests/a.sh", cwd=work) == a_bytes)
    check("clean tree: git_ls_tree_sh enumerates both required tests",
          sorted(p for _, _, p in d.git_ls_tree_sh(commit, "tests", cwd=work))
          == ["tests/a.sh", "tests/b.sh"])

    ctx = d.required_tests()
    check("clean tree: required_tests() succeeds and pins the commit",
          ctx["installed_commit"] == commit and ctx["required"] == ["tests/a.sh", "tests/b.sh"])

    def expect_refused(label):
        try:
            d.required_tests()
            check(f"{label}: required_tests() refuses (raised ValueError)", False)
        except ValueError:
            check(f"{label}: required_tests() refuses (raised ValueError)", True)

    # --- DIRTY: unstaged modification to a required, already-committed test --------------------
    (work / "tests" / "a.sh").write_text("#!/bin/sh\necho tampered\nexit 0\n")
    check("dirty: grader_drift flags it",
          any("tests/a.sh" in p for p in d.grader_drift(commit, work)))
    dirty_policy = d.execution_policy(work, commit)
    check("dirty: execution_policy still reports the COMMITTED hash, not the dirty one",
          dirty_policy["test_sha256"]["tests/a.sh"] == a_sha)
    expect_refused("dirty")
    sh("git", "checkout", "--", "tests/a.sh", cwd=work)  # restore

    # --- DELETED: a required, committed test removed from the working tree, uncommitted --------
    (work / "tests" / "b.sh").unlink()
    check("deleted: grader_drift flags it",
          any("tests/b.sh" in p for p in d.grader_drift(commit, work)))
    deleted_policy = d.execution_policy(work, commit)
    check("deleted: execution_policy STILL requires the deleted test (from the git tree)",
          "tests/b.sh" in deleted_policy["required"])
    check("deleted: execution_policy can still hash the vanished file from its committed blob",
          deleted_policy["test_sha256"]["tests/b.sh"] == b_sha)
    expect_refused("deleted")
    sh("git", "checkout", "--", "tests/b.sh", cwd=work)  # restore

    # --- REPLACED: the file at a required path is deleted and rewritten with different content,
    # simulating a worker swapping a grader for a permissive stub, all uncommitted -------------
    (work / "tests" / "a.sh").unlink()
    (work / "tests" / "a.sh").write_text("#!/bin/sh\n# rewritten grader stub\nexit 0\n")
    check("replaced: grader_drift flags it",
          any("tests/a.sh" in p for p in d.grader_drift(commit, work)))
    replaced_policy = d.execution_policy(work, commit)
    check("replaced: execution_policy still reports the ORIGINAL committed hash",
          replaced_policy["test_sha256"]["tests/a.sh"] == a_sha)
    check("replaced: the replacement's own hash is different (sanity check the mutation happened)",
          hashlib.sha256((work / "tests" / "a.sh").read_bytes()).hexdigest() != a_sha)
    expect_refused("replaced")
    sh("git", "checkout", "--", "tests/a.sh", cwd=work)  # restore

    # --- UNTRACKED: a brand-new tests/*.sh file that was never committed -----------------------
    (work / "tests" / "z.sh").write_text("#!/bin/sh\nexit 0\n")
    check("untracked: grader_drift flags it",
          any("tests/z.sh" in p for p in d.grader_drift(commit, work)))
    untracked_policy = d.execution_policy(work, commit)
    check("untracked: execution_policy does NOT add the untracked file to the required set",
          "tests/z.sh" not in untracked_policy["required"]
          and untracked_policy["required"] == ["tests/a.sh", "tests/b.sh"])
    expect_refused("untracked")
    (work / "tests" / "z.sh").unlink()  # restore

    # --- scripts/test drift is caught too (explicitly named as grader input in the fix) --------
    (work / "scripts" / "test").write_text("#!/bin/sh\necho tampered runner\n")
    check("scripts/test drift: grader_drift flags it",
          any("scripts/test" in p for p in d.grader_drift(commit, work)))
    sh("git", "checkout", "--", "scripts/test", cwd=work)  # restore

    # --- clean again after every mutation was reverted ------------------------------------------
    check("tree is clean again after all restores", d.grader_drift(commit, work) == [])
    final = d.execution_policy(work, commit)
    check("post-restore policy is byte-identical to the original baseline", final == baseline)

    # --- the actual grading entry point (run_candidate_test_phases) refuses too, before ever
    # touching isolation/systemd — proves the fix is wired into the real pipeline, not just the
    # helper functions -----------------------------------------------------------------------
    (work / "tests" / "a.sh").write_text("#!/bin/sh\necho tampered again\nexit 0\n")
    att = tmp / "att"; (att / "raw").mkdir(parents=True)
    lc = {"execution_policy": baseline, "test_runtime": None, "test_unit": "unused"}
    result = d.run_candidate_test_phases(lc, work, "deadbeef" * 5, att, 60, [])
    claims = " ".join(o.get("claim", "") for obs in result["tests"].values()
                      for o in obs["observations"])
    check("run_candidate_test_phases refuses to attest under working-tree drift",
          result["attested"] is False and "drift" in claims.lower())
    sh("git", "checkout", "--", "tests/a.sh", cwd=work)  # restore

    # --- and grades normally again on a clean tree, reaching per-test observations (candidate-read
    # runs as a plain subprocess — no isolation/systemd needed; candidate-isolated with no test
    # runtime configured fails closed on its own before ever calling isolated_run) --------------
    att2 = tmp / "att2"; (att2 / "raw").mkdir(parents=True)
    lc2 = {"execution_policy": baseline, "test_runtime": None, "test_unit": "unused"}
    result2 = d.run_candidate_test_phases(lc2, work, "deadbeef" * 5, att2, 60, [])
    check("run_candidate_test_phases: clean tree reaches a candidate-read observation",
          any(o.get("phase") == "candidate-read"
              for o in result2["tests"]["tests/a.sh"]["observations"]))
    check("run_candidate_test_phases: clean tree reaches a candidate-isolated observation",
          any(o.get("phase") == "candidate-isolated"
              for o in result2["tests"]["tests/b.sh"]["observations"]))
finally:
    d.ROOT, d.EXECUTION_POLICY = _orig_root, _orig_policy_path


# =========================================================================================
# Review round 1 (Codex FAIL) — five additional hardening findings.
# =========================================================================================
def make_repo(files: dict, commit_symlinks: dict | None = None):
    """Init a git repo, write `files` (rel -> text), optionally create committed symlinks
    (rel -> target), commit, return (work, commit)."""
    r = pathlib.Path(tempfile.mkdtemp()) / "w"
    sh("git", "init", "-qb", "main", str(r), cwd=r.parent)
    sh("git", "config", "user.email", "t@t", cwd=r)
    sh("git", "config", "user.name", "t", cwd=r)
    for rel, text in files.items():
        p = r / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        if rel.endswith(".sh") or rel == "scripts/test":
            p.chmod(0o755)
    for rel, target in (commit_symlinks or {}).items():
        p = r / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, str(p))
    sh("git", "add", "-A", cwd=r)
    sh("git", "commit", "-qm", "base", cwd=r)
    c = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(r),
                       capture_output=True, text=True).stdout.strip()
    return r, c

std_files = {
    "tests/a.sh": "#!/bin/sh\nexit 0\n",
    "tests/execution-policy.tsv": "tests/a.sh\tcandidate-read\tr\n",
    "scripts/test": "#!/bin/sh\necho runner\n",
    "scripts/requirements.txt": "dummy\n",
}

# --- Finding 4: refs/replace substitution must NOT reach our pinned reads --------------------
rr, rc = make_repo({**std_files, "tests/a.sh": "#!/bin/sh\necho ORIGINAL\nexit 0\n"})
orig_oid = subprocess.run(["git", "rev-parse", "HEAD:tests/a.sh"], cwd=str(rr),
                          capture_output=True, text=True).stdout.strip()
evil_oid = subprocess.run(["git", "hash-object", "-w", "--stdin"], cwd=str(rr),
                          input="#!/bin/sh\necho EVIL\nexit 0\n",
                          capture_output=True, text=True).stdout.strip()
sh("git", "replace", orig_oid, evil_oid, cwd=rr)
plain = subprocess.run(["git", "show", f"{rc}:tests/a.sh"], cwd=str(rr),
                       capture_output=True, text=True).stdout
check("replace-object is actually active (plain git show returns the replacement)",
      "EVIL" in plain)
check("git_show_bytes ignores the replacement (GIT_NO_REPLACE_OBJECTS)",
      b"ORIGINAL" in d.git_show_bytes(rc, "tests/a.sh", cwd=rr)
      and b"EVIL" not in d.git_show_bytes(rc, "tests/a.sh", cwd=rr))
check("execution_policy hashes the ORIGINAL blob, not the replacement",
      d.execution_policy(rr, rc)["test_sha256"]["tests/a.sh"]
      == hashlib.sha256(b"#!/bin/sh\necho ORIGINAL\nexit 0\n").hexdigest())
check("grader_drift is clean despite the planted replacement (disk == committed)",
      d.grader_drift(rc, rr) == [])

# --- Finding 3: assume-unchanged / skip-worktree tampering must STILL be detected ------------
for flag in ("--assume-unchanged", "--skip-worktree"):
    ur, uc = make_repo(std_files)
    sh("git", "update-index", flag, "tests/a.sh", cwd=ur)
    (ur / "tests" / "a.sh").write_text("#!/bin/sh\necho TAMPERED\nexit 0\n")
    hidden = (subprocess.run(["git", "status", "--porcelain"], cwd=str(ur),
                             capture_output=True, text=True).stdout.strip() == ""
              and subprocess.run(["git", "diff", "--name-only"], cwd=str(ur),
                                 capture_output=True, text=True).stdout.strip() == "")
    check(f"{flag}: git status/diff are blind to the tamper (precondition)", hidden)
    check(f"{flag}: grader_drift detects it anyway (direct byte compare)",
          any("tests/a.sh" in p for p in d.grader_drift(uc, ur)))

# --- Finding 5: a committed SYMLINK manifest or test must be rejected ------------------------
sm, smc = make_repo({"tests/a.sh": "#!/bin/sh\nexit 0\n", "scripts/test": "#!/bin/sh\n",
                     "real.tsv": "tests/a.sh\tcandidate-read\tr\n"},
                    commit_symlinks={"tests/execution-policy.tsv": "../real.tsv"})
try:
    d.execution_policy(sm, smc)
    check("committed symlink manifest rejected", False)
except ValueError as e:
    check("committed symlink manifest rejected",
          "symlink" in str(e).lower() or "regular" in str(e).lower())

st, stc = make_repo({"tests/a.sh": "#!/bin/sh\nexit 0\n", "scripts/test": "#!/bin/sh\n",
                     "tests/execution-policy.tsv": "tests/a.sh\tcandidate-read\tr\n"},
                    commit_symlinks={"tests/evil.sh": "/etc/passwd"})
try:
    d.execution_policy(st, stc)
    check("committed symlink test rejected", False)
except ValueError as e:
    check("committed symlink test rejected",
          "symlink" in str(e).lower() or "regular" in str(e).lower())
check("grader_drift also flags a committed symlink test",
      any("evil.sh" in p for p in d.grader_drift(stc, st)))

# --- Finding 1: the integration gate refuses a drifted post-merge tree ----------------------
ir, ic = make_repo(std_files)
_ir_root = d.ROOT
d.ROOT = ir
try:
    check("integration gate: clean post-merge tree passes",
          d.integration_grade_gate(ir) == (ic, []))
    (ir / "scripts" / "test").write_text("#!/bin/sh\necho tampered runner\n")
    check("integration gate: dirty scripts/test refused",
          any("scripts/test" in p for p in d.integration_grade_gate(ir)[1]))
    sh("git", "checkout", "--", "scripts/test", cwd=ir)
    (ir / "tests" / "z.sh").write_text("#!/bin/sh\nexit 0\n")
    check("integration gate: untracked tests/*.sh refused",
          any("z.sh" in p for p in d.integration_grade_gate(ir)[1]))
    (ir / "tests" / "z.sh").unlink()
    (ir / "tests" / "a.sh").unlink()
    check("integration gate: deleted tracked test refused",
          any("a.sh" in p for p in d.integration_grade_gate(ir)[1]))
    sh("git", "checkout", "--", "tests/a.sh", cwd=ir)
    (ir / "tests" / "execution-policy.tsv").write_text("tests/a.sh\tbox-precondition\tx\n")
    check("integration gate: altered manifest refused",
          any("execution-policy.tsv" in p for p in d.integration_grade_gate(ir)[1]))
    sh("git", "checkout", "--", "tests/execution-policy.tsv", cwd=ir)
    check("integration gate: clean again after restores",
          d.integration_grade_gate(ir)[1] == [])
finally:
    d.ROOT = _ir_root

# --- Finding 2: box + candidate-read tests execute IMMUTABLE committed bytes -----------------
# The graded run must come from a materialized blob at an unpredictable path (not the swappable
# ROOT/rel), while the test's own dirname("$0")/.. still resolves the repo root.
echo0 = ('#!/bin/sh\necho "RAN_FROM=$0"\n'
         'echo "SELF_ROOT=$(cd "$(dirname "$0")/.." && pwd)"\nexit 0\n')
_saved = (d.ROOT, d.EXECUTION_POLICY, d.STATE)
try:
    # candidate-read
    cr, crc = make_repo({**std_files, "tests/a.sh": echo0})
    d.ROOT, d.EXECUTION_POLICY = cr, cr / "tests" / "execution-policy.tsv"
    d.STATE = pathlib.Path(tempfile.mkdtemp())
    pol = d.execution_policy(cr, crc)
    catt = pathlib.Path(tempfile.mkdtemp()); (catt / "raw").mkdir(parents=True)
    d.run_candidate_test_phases({"execution_policy": pol, "test_runtime": None,
                                 "test_unit": "u"}, cr, "d" * 40, catt, 60, [])
    crlog = (catt / "raw" / "candidate-read-a.log").read_text()
    check("candidate-read executed a materialized nonce, not tests/a.sh",
          "/tests/.b4run-" in crlog and f"RAN_FROM={cr}/tests/a.sh" not in crlog)
    check("candidate-read self-location still resolves the repo root",
          f"SELF_ROOT={cr}" in crlog)
    check("candidate-read left no nonce behind (cleaned up)",
          not any(p.name.startswith(".b4run-") for p in (cr / "tests").iterdir()))

    # box-precondition
    br, brc = make_repo({**std_files, "tests/a.sh": echo0,
                         "tests/execution-policy.tsv": "tests/a.sh\tbox-precondition\tx\n"})
    d.ROOT, d.EXECUTION_POLICY = br, br / "tests" / "execution-policy.tsv"
    d.STATE = pathlib.Path(tempfile.mkdtemp())
    bpol = d.execution_policy(br, brc)
    batt = pathlib.Path(tempfile.mkdtemp()); (batt / "raw").mkdir(parents=True)
    d.run_box_preconditions(batt, bpol)
    brlog = (batt / "raw" / "box-precondition-a.log").read_text()
    check("box-precondition executed a materialized nonce, not tests/a.sh",
          "/tests/.b4run-" in brlog and f"RAN_FROM={br}/tests/a.sh" not in brlog)
    check("box-precondition self-location still resolves the repo root",
          f"SELF_ROOT={br}" in brlog)
    check("box-precondition left no nonce behind (cleaned up)",
          not any(p.name.startswith(".b4run-") for p in (br / "tests").iterdir()))
finally:
    d.ROOT, d.EXECUTION_POLICY, d.STATE = _saved

print(f"\n{'PASS' if not fails else 'FAIL'}: B4 test-provenance guards ({len(fails)} failed)")
sys.exit(1 if fails else 0)
PY
