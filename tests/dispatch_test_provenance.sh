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
# git repo — no workers launched, no quota burned. Same venv-skip contract as
# tests/dispatch_gate4.sh: dispatch.py imports pyyaml + jsonschema from the dispatcher venv
# (.venv — CI installs it too); without a usable venv, SKIP LOUDLY, never a silent pass.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_test_provenance.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test needs the dispatcher venv; CI installs it)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import hashlib, importlib.util, os, pathlib, subprocess, tempfile, sys, time

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
    result = d.run_candidate_test_phases(lc, work, "deadbeef" * 5, att, time.time() + 3600, [])
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
    result2 = d.run_candidate_test_phases(lc2, work, "deadbeef" * 5, att2, time.time() + 3600, [])
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
# The attack-precondition probes must see DEFAULT git behavior even when the harness itself
# runs with GIT_NO_REPLACE_OBJECTS=1 exported (the dispatcher's grader env does, round-3).
_replace_on = {k: v for k, v in os.environ.items() if k != "GIT_NO_REPLACE_OBJECTS"}
plain = subprocess.run(["git", "show", f"{rc}:tests/a.sh"], cwd=str(rr),
                       capture_output=True, text=True, env=_replace_on).stdout
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

# --- Findings 1+2 (round 2): graders execute from an IMMUTABLE tree OUTSIDE the working tree ---
# Round 1's nonce-under-tests/ is gone (it regressed grader_drift, and a same-uid rename could
# still race the well-known path). A grader that echoes $0, its self-located root, and a data
# dependency read via that root proves: (a) the executed path is OUTSIDE the repo working tree,
# (b) self-location resolves the grader tree, (c) the data dependency is the PINNED commit's even
# when the working-tree copy is tampered (finding 3), (d) no dotfile is left under tests/ (2a).
grader = ('#!/bin/sh\necho "RAN_FROM=$0"\n'
          'echo "SELF_ROOT=$(cd "$(dirname "$0")/.." && pwd)"\n'
          'echo "DEP=$(cat "$(dirname "$0")/../data/dep.txt")"\n'
          'echo "NOREPLACE=$GIT_NO_REPLACE_OBJECTS"\nexit 0\n')
dep_files = {**std_files, "tests/a.sh": grader, "data/dep.txt": "PINNED-DEP\n"}
_saved = (d.ROOT, d.EXECUTION_POLICY, d.STATE)
try:
    for label, mode, logname, runner in (
        ("candidate-read", "candidate-read", "candidate-read-a.log",
         lambda att, pol, root: d.run_candidate_test_phases(
             {"execution_policy": pol, "test_runtime": None, "test_unit": "u"},
             root, "d" * 40, att, time.time() + 3600, [])),
        ("box-precondition", "box-precondition", "box-precondition-a.log",
         lambda att, pol, root: d.run_box_preconditions(att, pol)),
    ):
        gr, grc = make_repo({**dep_files, "tests/execution-policy.tsv": f"tests/a.sh\t{mode}\tx\n"})
        d.ROOT, d.EXECUTION_POLICY = gr, gr / "tests" / "execution-policy.tsv"
        d.STATE = pathlib.Path(tempfile.mkdtemp())
        pol = d.execution_policy(gr, grc)
        # tamper the WORKING-TREE data dependency — it is not a grader_drift-tracked *.sh path, so
        # grading proceeds; the grader must still read the PINNED bytes from the immutable tree.
        (gr / "data" / "dep.txt").write_text("TAMPERED-DEP\n")
        att = pathlib.Path(tempfile.mkdtemp()); (att / "raw").mkdir(parents=True)
        runner(att, pol, gr)
        logtext = (att / "raw" / logname).read_text()
        check(f"{label}: executed a path OUTSIDE the repo working tree",
              "RAN_FROM=/" in logtext and f"RAN_FROM={gr}/" not in logtext)
        check(f"{label}: self-location resolves the immutable grader tree, not the working tree",
              "SELF_ROOT=/" in logtext and f"SELF_ROOT={gr}" not in logtext)
        check(f"{label}: read the PINNED data dependency, not the tampered working-tree copy",
              "DEP=PINNED-DEP" in logtext and "TAMPERED-DEP" not in logtext)
        check(f"{label}: left NO file under tests/ (round-1 dotfile regression is gone)",
              sorted(p.name for p in (gr / "tests").iterdir())
              == ["a.sh", "execution-policy.tsv"])
        check(f"{label}: grader_drift stays clean afterward (no nonce pollution, finding 2a)",
              d.grader_drift(grc, gr) == [])
        check(f"{label}: GIT_NO_REPLACE_OBJECTS=1 exported into the grader subprocess env (round-3)",
              "NOREPLACE=1" in logtext)
finally:
    d.ROOT, d.EXECUTION_POLICY, d.STATE = _saved

# --- Finding 4: refs/replace must not reach the integrity/scope object reads ------------------
# scope_check() parses `git diff base..wc`. Plant a replace that makes the base resolve to the
# candidate tree (so a replace-enabled diff is empty and scope would PASS vacuously); with
# --no-replace-objects the gate must still see the real, out-of-scope change.
sr, _ = make_repo({"in/a.txt": "base\n"})
sh("git", "config", "user.email", "t@t", cwd=sr); sh("git", "config", "user.name", "t", cwd=sr)
sbase = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(sr),
                       capture_output=True, text=True).stdout.strip()
(sr / "outside.txt").write_text("oops\n")
sh("git", "add", "-A", cwd=sr); sh("git", "commit", "-qm", "worker", cwd=sr)
swc = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(sr),
                     capture_output=True, text=True).stdout.strip()
sh("git", "replace", sbase, swc, cwd=sr)   # base now resolves to the candidate commit
replaced_diff = subprocess.run(["git", "diff", "--name-only", f"{sbase}..{swc}"], cwd=str(sr),
                               capture_output=True, text=True, env=_replace_on).stdout.strip()
check("refs/replace really neutralizes a plain diff (empty base..wc)", replaced_diff == "")
sc = d.scope_check(sr, sbase, swc, ["in/**"])
check("scope_check ignores the replacement and still catches the out-of-scope change",
      sc["result"] == "FAIL" and sc["out_of_scope"] == ["outside.txt"])
# integrity() ancestry read is routed through the same no-replace wrapper (git_cp)
integ, ok = d.integrity(sr, sbase, swc)
check("integrity descends_from_base is computed with replace disabled",
      integ["descends_from_base"] is True)

# --- Round-3 fix 1: scripts/requirements.txt is in the drift-checked grader set --------------
# trusted_test_runtime() hashes ROOT/scripts/requirements.txt off the working tree to authorize a
# dependency closure, so a dirty requirements.txt must trip grader_drift() and refuse grading.
rq, rqc = make_repo(std_files)
check("requirements.txt: clean tree passes drift", d.grader_drift(rqc, rq) == [])
(rq / "scripts" / "requirements.txt").write_text("evil-dep==6.6.6\n")
check("requirements.txt: dirty requirements.txt trips grader_drift",
      any("scripts/requirements.txt" in p for p in d.grader_drift(rqc, rq)))
sh("git", "checkout", "--", "scripts/requirements.txt", cwd=rq)
(rq / "scripts" / "requirements.txt").unlink()
check("requirements.txt: deleted requirements.txt trips grader_drift",
      any("scripts/requirements.txt" in p for p in d.grader_drift(rqc, rq)))
sh("git", "checkout", "--", "scripts/requirements.txt", cwd=rq)
check("requirements.txt: clean again after restore", d.grader_drift(rqc, rq) == [])
# a committed symlink requirements.txt is rejected too (bytes+type, like the manifest)
sy, syc = make_repo({"tests/a.sh": "#!/bin/sh\nexit 0\n", "scripts/test": "#!/bin/sh\n",
                     "tests/execution-policy.tsv": "tests/a.sh\tcandidate-read\tr\n",
                     "real-req.txt": "pkg==1.0\n"},
                    commit_symlinks={"scripts/requirements.txt": "../real-req.txt"})
check("requirements.txt: committed symlink requirements.txt is refused",
      any("scripts/requirements.txt" in p and ("regular" in p or "symlink" in p.lower())
          for p in d.grader_drift(syc, sy)))

# --- Round-3 fix 3: manifest_after is hashed from the PINNED commit, not the working tree ------
# A working-tree manifest swap after the drift check (a race we can't reproduce, so we bypass the
# drift gate) must not change manifest_sha256_after: it is read from the pinned commit.
mr, mrc = make_repo({**std_files, "tests/a.sh": "#!/bin/sh\nexit 0\n"})
_saved2 = (d.ROOT, d.EXECUTION_POLICY, d.STATE, d.grader_drift)
try:
    d.ROOT, d.EXECUTION_POLICY = mr, mr / "tests" / "execution-policy.tsv"
    d.STATE = pathlib.Path(tempfile.mkdtemp())
    mpol = d.execution_policy(mr, mrc)
    committed_manifest_sha = mpol["manifest_sha256"]
    d.grader_drift = lambda *a, **k: []          # bypass the up-front gate to simulate the race
    (mr / "tests" / "execution-policy.tsv").write_text("tests/a.sh\tbox-precondition\tSWAPPED\n")
    tampered_sha = hashlib.sha256((mr / "tests" / "execution-policy.tsv").read_bytes()).hexdigest()
    matt = pathlib.Path(tempfile.mkdtemp()); (matt / "raw").mkdir(parents=True)
    res = d.run_candidate_test_phases({"execution_policy": mpol, "test_runtime": None,
                                       "test_unit": "u"}, mr, "d" * 40, matt, time.time() + 3600, [])
    obs = res["tests"]["tests/a.sh"]["observations"][-1]
    check("manifest_after is the PINNED manifest hash, not the swapped working-tree one",
          obs["manifest_sha256_after"] == committed_manifest_sha
          and obs["manifest_sha256_after"] != tampered_sha)
finally:
    d.ROOT, d.EXECUTION_POLICY, d.STATE, d.grader_drift = _saved2

print(f"\n{'PASS' if not fails else 'FAIL'}: B4 test-provenance guards ({len(fails)} failed)")
sys.exit(1 if fails else 0)
PY
