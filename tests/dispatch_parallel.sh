#!/usr/bin/env bash
# Gate 3 part 3 — regression test for the two parallelism guards added when MAX_PARALLEL went 1->2:
#
#   1. claim_slot()  — the concurrency claim must be ATOMIC and enforce both limits: at most
#      MAX_PARALLEL live attempts across all specs, and at most one live attempt per spec (state
#      files are keyed per-spec, so a second live attempt of one spec would clobber the first's).
#   2. base_moved()  — the stale-base guard: an attempt whose base branch advanced while it ran
#      (a sibling integrated) must be detected so it is refused at push and re-run fresh.
#
# This exercises the REAL functions in scripts/dispatch.py against a REAL temp git repo — it does
# not re-implement the logic. dispatch.py imports pyyaml + jsonschema, which live in the box venv
# (.venv) and are NOT present on the CI runner. So: run for real on the box; SKIP LOUDLY in CI.
# The dispatcher is box-only infrastructure and is never executed in CI anyway (CI guards the
# product tests). A silent skip would be dishonest, hence the explicit SKIP line.
set -euo pipefail
cd "$(dirname "$0")/.."

PY=".venv/bin/python"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_parallel.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import importlib.util, json, tempfile, subprocess, pathlib, sys

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# --- Guard 1: atomic concurrency claim -------------------------------------------------------
d.STATE = pathlib.Path(tempfile.mkdtemp())   # isolate from real .orchestrator/state
def claim(spec_id):
    try:
        d.claim_slot(spec_id, {"attempt_id": f"{spec_id}-1", "spec_id": spec_id,
                               "status": "launching", "attempt": 1})
        return None
    except SystemExit as e:
        return e.code

# MAX_PARALLEL is configurable (env ORCH_MAX_PARALLEL); test the guard relative to its value, not a
# hardcoded number, so the assertion stays valid whatever the bound is.
N = d.MAX_PARALLEL
check(f"MAX_PARALLEL is a positive int ({N})", isinstance(N, int) and N >= 1)
ids = [f"SPEC-P{i:02d}" for i in range(N + 1)]
for i in range(N):
    check(f"spec {i+1}/{N} claims a slot", claim(ids[i]) is None)
check(f"spec {N+1} refused over the limit (exit 8)", claim(ids[N]) == 8)
check("same spec re-claim refused (8)",              claim(ids[0]) == 8)
# free a slot: mark the first terminal → the over-limit spec now fits
p = d.STATE / f"{ids[0]}.json"; st = json.loads(p.read_text()); st["status"] = "passed_pr_opened"
p.write_text(json.dumps(st))
check("freed slot reopens for the next spec",        claim(ids[N]) is None)

# --- Guard 2: stale-base detection ------------------------------------------------------------
tmp = pathlib.Path(tempfile.mkdtemp())
def sh(*a, cwd): subprocess.run(a, cwd=str(cwd), check=True, capture_output=True)
def out(*a, cwd): return subprocess.run(a, cwd=str(cwd), check=True, capture_output=True, text=True).stdout.strip()
origin, work = tmp/"origin.git", tmp/"work"
sh("git","init","--bare","-b","ready-for-main",str(origin), cwd=tmp)
sh("git","init","-b","ready-for-main",str(work), cwd=tmp)
sh("git","config","user.email","t@t", cwd=work); sh("git","config","user.name","t", cwd=work)
sh("git","remote","add","origin",str(origin), cwd=work)
(work/"a.txt").write_text("1\n"); sh("git","add","-A", cwd=work); sh("git","commit","-qm","base", cwd=work)
sh("git","push","-q","origin","ready-for-main", cwd=work)
base_sha = out("git","rev-parse","HEAD", cwd=work)

cur, moved = d.base_moved(work, "ready-for-main", base_sha)
check("unchanged base -> not stale", (moved is False) and cur == base_sha)

# a sibling integrates: advance origin/ready-for-main from a second clone
sib = tmp/"sib"; sh("git","clone","-q","-b","ready-for-main",str(origin),str(sib), cwd=tmp)
sh("git","config","user.email","s@s", cwd=sib); sh("git","config","user.name","s", cwd=sib)
(sib/"b.txt").write_text("2\n"); sh("git","add","-A", cwd=sib); sh("git","commit","-qm","sibling", cwd=sib)
sh("git","push","-q","origin","ready-for-main", cwd=sib)
new_tip = out("git","rev-parse","HEAD", cwd=sib)

cur2, moved2 = d.base_moved(work, "ready-for-main", base_sha)
check("advanced base -> stale, reports new tip", (moved2 is True) and cur2 == new_tip)

# --- Guard 3: autonomy grant loader (Level 1.5 auto-merge is gated on it) ----------------------
import os
_atmp = pathlib.Path(tempfile.mkdtemp())
d.AUTONOMY = _atmp / "AUTONOMY.json"
d.AUTONOMY_LOCAL = _atmp / "AUTONOMY.local.json"   # isolate the gitignored local override too
check("no grant file -> autonomy off", d.load_autonomy() is None)
d.AUTONOMY.write_text(json.dumps({"enabled": False, "target_branch": "ready-for-main"}))
check("enabled:false -> autonomy off", d.load_autonomy() is None)
d.AUTONOMY.write_text(json.dumps({"enabled": True, "target_branch": "ready-for-main",
                                  "allowed_risk_class": ["low"], "main_human_only": True}))
g = d.load_autonomy()
check("enabled:true -> grant loaded, main stays human", g is not None and g.get("main_human_only") is True)

print(f"\n{'PASS' if not fails else 'FAIL'}: dispatch parallelism + autonomy guards ({len(fails)} failed)")
sys.exit(1 if fails else 0)
PY
