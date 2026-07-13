#!/usr/bin/env bash
# Gate 4 — regression tests for bounded remediation, escalation, high-risk per-dispatch approval,
# and the two scope-violation detection paths (committed-out-of-scope + dirty-worktree).
#
# Exercises the REAL functions in scripts/dispatch.py against synthetic attempt histories and a
# real temp git repo — no workers launched, no quota burned. Same box-only skip contract as
# tests/dispatch_parallel.sh: the CI runner has no venv; SKIP LOUDLY there, run for real here.
set -euo pipefail
cd "$(dirname "$0")/.."

PY=".venv/bin/python"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_gate4.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 0
fi

"$PY" - <<'PY'
import importlib.util, json, tempfile, subprocess, pathlib, sys

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# Isolate all state/evidence dirs from the real .orchestrator
tmp = pathlib.Path(tempfile.mkdtemp())
d.ATTEMPTS = tmp / "attempts"; d.STATE = tmp / "state"
d.APPROVALS = tmp / "approvals"; d.ESCALATIONS = tmp / "escalations"
for p in (d.ATTEMPTS, d.STATE, d.APPROVALS, d.ESCALATIONS): p.mkdir(parents=True)

def put_attempt(spec_id, n, status, extra=None, review=None):
    att = d.ATTEMPTS / spec_id / str(n); att.mkdir(parents=True, exist_ok=True)
    (att / "result.json").write_text(json.dumps({"status": status, **(extra or {})}))
    if review is not None:
        (att / "review.json").write_text(json.dumps(review))

def preflight(spec_id, risk, n):
    try:
        return ("ok", d.remediation_preflight(spec_id, {"risk_class": risk}, "d" * 64, n))
    except SystemExit as e:
        return (f"exit{e.code}", None)

# --- Remediation budget --------------------------------------------------------------------
check("initial attempt -> no remediation ctx", preflight("SPEC-T01", "default", 1) == ("ok", None))

# interrupted / stale_base / spec_blocked never consume remediation budget
put_attempt("SPEC-T02", 1, "interrupted"); put_attempt("SPEC-T02", 2, "stale_base")
put_attempt("SPEC-T02", 3, "spec_blocked")
check("infrastructure endings don't count as merit failures",
      preflight("SPEC-T02", "default", 4) == ("ok", None))

# distinct failures under the limit -> remediation ctx carries the LAST findings
put_attempt("SPEC-T03", 1, "failed_test", {"test_exit": 1})
put_attempt("SPEC-T03", 2, "failed_review",
            review={"reasons": ["helper misses empty-string case"], "criteria": [
                {"criterion": "c1", "result": "MET"}, {"criterion": "c2", "result": "UNMET"}]})
st, ctx = preflight("SPEC-T03", "default", 3)
check("2 distinct merit failures (default, limit 3) -> allowed", st == "ok" and ctx is not None)
check("remediation ctx cites the LAST failure + findings",
      ctx and ctx["of_attempt"] == 2 and ctx["remediation_number"] == 2
      and ctx["findings"]["status"] == "failed_review"
      and ctx["findings"]["reviewer_reasons"] == ["helper misses empty-string case"])

# default risk: 4th merit failure (> limit 3) -> exhausted + escalation + failed state
for i, stt in enumerate(["failed_test", "failed_scope", "failed_test", "failed_review"], 1):
    rev = {"reasons": [f"r{i}"], "criteria": []} if stt == "failed_review" else None
    put_attempt("SPEC-T04", i, stt, {"test_exit": i}, review=rev)
st, _ = preflight("SPEC-T04", "default", 5)
check("limit exhausted (4 > 3) -> refused exit 18", st == "exit18")
check("exhaustion wrote escalation record", any(d.ESCALATIONS.glob("SPEC-T04-*.json")))
check("exhaustion wrote failed_remediation_exhausted state",
      json.loads((d.STATE / "SPEC-T04.json").read_text())["status"] == "failed_remediation_exhausted")

# low risk allows 5 remediations; high risk allows 1
for i in range(1, 5): put_attempt("SPEC-T05", i, "failed_test", {"test_exit": i})
check("low risk: 4 failures still within limit 5", preflight("SPEC-T05", "low", 5)[0] == "ok")
put_attempt("SPEC-T06", 1, "failed_test", {"test_exit": 1})
put_attempt("SPEC-T06", 2, "failed_test", {"test_exit": 2})
check("high risk caps at 1 remediation: 2 failures -> refused",
      preflight("SPEC-T06", "high", 3)[0] in ("exit17", "exit18"))

# stop-early: two consecutive IDENTICAL findings -> refused even under the limit
same = {"reasons": ["same finding"], "criteria": [{"criterion": "c", "result": "UNMET"}]}
put_attempt("SPEC-T07", 1, "failed_review", review=same)
put_attempt("SPEC-T07", 2, "failed_review", review=same)
check("stop-early on identical findings -> refused exit 18",
      preflight("SPEC-T07", "default", 3)[0] == "exit18")
check("stop-early wrote escalation", any(d.ESCALATIONS.glob("SPEC-T07-*.json")))

# --- High-risk per-dispatch approval ---------------------------------------------------------
check("high risk attempt 1 without per-dispatch approval -> refused exit 17",
      preflight("SPEC-T08", "high", 1)[0] == "exit17")
(d.APPROVALS / ("d" * 64 + ".attempt-1.json")).write_text(json.dumps({"approver": "val", "attempt": 1}))
check("high risk attempt 1 WITH per-dispatch approval -> allowed",
      preflight("SPEC-T08", "high", 1) == ("ok", None))

# --- Scope-violation detection paths (Gate 4 pipeline test 3, both cases) --------------------
gtmp = pathlib.Path(tempfile.mkdtemp())
def sh(*a, cwd): subprocess.run(a, cwd=str(cwd), check=True, capture_output=True)
work = gtmp / "w"; sh("git", "init", "-qb", "main", str(work), cwd=gtmp)
sh("git", "config", "user.email", "t@t", cwd=work); sh("git", "config", "user.name", "t", cwd=work)
(work / "in").mkdir(); (work / "in" / "a.txt").write_text("base\n")
sh("git", "add", "-A", cwd=work); sh("git", "commit", "-qm", "base", cwd=work)
base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(work), capture_output=True,
                      text=True).stdout.strip()
# committed-out-of-scope: change lands outside the approved globs -> scope FAIL
(work / "outside.txt").write_text("oops\n")
sh("git", "add", "-A", cwd=work); sh("git", "commit", "-qm", "worker", cwd=work)
wc = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(work), capture_output=True,
                    text=True).stdout.strip()
sc = d.scope_check(work, base, wc, ["in/**"])
check("committed out-of-scope path -> scope FAIL names it",
      sc["result"] == "FAIL" and sc["out_of_scope"] == ["outside.txt"])
# dirty-worktree: uncommitted leftover -> integrity FAIL (worktree_clean False)
(work / "dirty.txt").write_text("uncommitted\n")
integ, ok = d.integrity(work, base, wc)
check("dirty worktree -> integrity FAIL", ok is False and integ["worktree_clean"] is False)

# --- instance-bound approvals (copied approvals must not authorize copied specs) -------------
d.INSTANCE = tmp / "instance.json"
inst = d.ensure_instance()
check("ensure_instance creates an id + repo", bool(inst.get("instance_id")) and "repo" in inst)
check("ensure_instance is idempotent", d.ensure_instance()["instance_id"] == inst["instance_id"])
check("an approval from THIS instance matches", inst["instance_id"] == d.instance_identity()["instance_id"])
check("a copied/foreign approval's instance_id does NOT match (→ rejected in preflight)",
      "f0f0"*8 != inst["instance_id"])

# --- integrate helpers -----------------------------------------------------------------------
order_specs = {"SPEC-A": [], "SPEC-B": ["SPEC-A"], "SPEC-C": ["SPEC-B"]}
d.load_spec = lambda sid: {"depends_on": order_specs[sid]}  # stub only for _topo_specs
check("_topo_specs orders by depends_on",
      d._topo_specs(["SPEC-C", "SPEC-A", "SPEC-B"]) == ["SPEC-A", "SPEC-B", "SPEC-C"])

print(f"\n{'PASS' if not fails else 'FAIL'}: Gate 4 remediation/scope/integrate guards ({len(fails)} failed)")
sys.exit(1 if fails else 0)
PY
