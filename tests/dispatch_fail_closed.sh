#!/usr/bin/env bash
# Fail-closed regressions for audit mediums B9/B10/B14/B16 (fix batch M1).
#
# Exercises the REAL functions in scripts/dispatch.py against synthetic state and a real temp git
# repo — no workers launched, no reviewer called (the claude invocation is monkeypatched). Same
# venv-skip contract as tests/dispatch_gate4.sh: no usable venv means SKIP LOUDLY, never a pass.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_fail_closed.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test needs the dispatcher venv; CI installs it)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import contextlib, importlib.util, inspect, io, json, pathlib, subprocess, sys, tempfile

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

tmp = pathlib.Path(tempfile.mkdtemp())
d.STATE = tmp / "state"; d.STATE.mkdir(parents=True)

def claim_dies(name, expect_die):
    try:
        d.claim_slot("SPEC-999", {"attempt_id": "SPEC-999-1", "spec_id": "SPEC-999",
                                  "status": "launching"})
        died = False
    except SystemExit as e:
        died = (e.code == 8)
    # claim_slot may have written the launching state; clean it for the next case
    for p in d.STATE.glob("SPEC-999*.json"):
        p.unlink()
    check(name, died == expect_die)

# B10: malformed canonical state file blocks the claim (exit 8)...
(d.STATE / "SPEC-001.json").write_text('{"truncated": ')
claim_dies("B10 malformed canonical state blocks claim", True)
(d.STATE / "SPEC-001.json").unlink()

# ...a JSON-valid non-object canonical value blocks it too...
(d.STATE / "SPEC-002.json").write_text('"just a string"')
claim_dies("B10 non-object canonical state blocks claim", True)
(d.STATE / "SPEC-002.json").unlink()

# ...but a malformed ADVISORY health sidecar must NOT block launches.
(d.STATE / "SPEC-003.health.json").write_text('{"truncated": ')
claim_dies("B10 malformed health sidecar does not block claim", False)
(d.STATE / "SPEC-003.health.json").unlink()

# B10: reconcile REPORTS malformed canonical state (and skips health sidecars) — including
# JSON-VALID non-object values, which previously crashed cmd_reconcile at st.get() before the
# malformed-state scan ran (owner-extension round-1).
(d.STATE / "SPEC-004.json").write_text('{"truncated": ')
(d.STATE / "SPEC-005.health.json").write_text('{"truncated": ')
(d.STATE / "SPEC-006.json").write_text('"just a string"')
(d.STATE / "SPEC-007.health.json").write_text('"just a string"')
d._list_codex_units = lambda: ([], True)
buf = io.StringIO()
crashed = False
with contextlib.redirect_stdout(buf):
    try:
        d.cmd_reconcile()
    except SystemExit:
        pass
    except Exception:
        crashed = True
check("B10 reconcile survives valid-but-non-object state values", not crashed)
out = json.loads(buf.getvalue())
mal = [m["file"] for m in out.get("malformed_state", [])]
check("B10 reconcile reports the malformed canonical file", any("SPEC-004" in f for f in mal))
check("B10 reconcile reports the non-object canonical file", any("SPEC-006" in f for f in mal))
check("B10 reconcile does not report health sidecars",
      not any("SPEC-005" in f or "SPEC-007" in f for f in mal))
for n in ("SPEC-004.json", "SPEC-005.health.json", "SPEC-006.json", "SPEC-007.health.json"):
    (d.STATE / n).unlink()

# B14: a failing git diff yields a FAILing scope result, never an empty PASS.
repo = tmp / "repo"; repo.mkdir()
subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q",
                "--allow-empty", "-m", "x"], cwd=repo, check=True)
res = d.scope_check(repo, "no-such-base", "no-such-head", ["**"])
check("B14 nonzero git diff fails scope", res["result"] == "FAIL" and "error" in res)
check("B14 failed diff reports no changed files as in-scope", res["changed"] == [])

# B16: reviewer envelope refused on nonzero exit; neutral cwd is outside the repo; hardened flags
# present. Heavy collaborators are monkeypatched so ONLY the invocation contract is under test.
d.git = lambda *a, **k: "diff --git a/x b/x"
d._verdict_schema_for_attempt = lambda att: {"type": "object"}
d.snapshot_spec_text = lambda att, digest: "id: SPEC-900"
captured = {}
def fake_run(cmd, **kw):
    captured["cmd"] = cmd; captured["cwd"] = kw.get("cwd")
    return subprocess.CompletedProcess(cmd, 1, stdout=json.dumps(
        {"result": json.dumps({"verdict": "PASS"})}), stderr="")
d.run = fake_run
att = tmp / "attempts" / "SPEC-900" / "1"; (att / "raw").mkdir(parents=True)
lc = {"worktree": str(repo), "base_sha": "b" * 40, "spec_digest": "d" * 64,
      "reviewer_model": "claude-fable-5", "reviewer_effort": "high"}
verdict, raw = d.review(att, "SPEC-900", lc, "c" * 40)
check("B16 nonzero reviewer exit yields no verdict even with valid JSON", verdict is None)
check("B16 reviewer runs from a cwd outside the repo",
      captured["cwd"] is not None and
      not pathlib.Path(captured["cwd"]).resolve().is_relative_to(d.ROOT.resolve()))
for flag in ("--safe-mode", "--strict-mcp-config", "--no-session-persistence"):
    check(f"B16 reviewer invocation carries {flag}", flag in captured["cmd"])
check("B16 reviewer invocation empties the tool surface",
      "--tools" in captured["cmd"] and
      captured["cmd"][captured["cmd"].index("--tools") + 1] == "")

# B9: the post-merge suite launch (run_integrate_suite) forces strict mode AND hands the suite
# a usable interpreter — without ORCH_TEST_PY the grader tree (no gitignored .venv) would skip
# the venv-dependent dispatcher self-tests, and strict mode turns that skip into a guaranteed
# integrate failure. Exercised through the REAL launch helper with run() captured, so the
# command, cwd, and environment under test are exactly what cmd_integrate passes.
suite = {}
def fake_suite_run(cmd, **kw):
    suite["cmd"] = cmd; suite["cwd"] = kw.get("cwd"); suite["env"] = kw.get("env")
    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
d.run = fake_suite_run
gtree = tmp / "gtree"; (gtree / "scripts").mkdir(parents=True)
d.run_integrate_suite(gtree)
check("B9 suite launch runs the grader tree's own scripts/test in that tree",
      suite["cmd"] == [str(gtree / "scripts" / "test")] and suite["cwd"] == str(gtree))
check("B9 suite launch forces ORCH_TEST_STRICT=1", suite["env"].get("ORCH_TEST_STRICT") == "1")
check("B9 suite launch disables replace objects",
      suite["env"].get("GIT_NO_REPLACE_OBJECTS") == "1")
check("B9 suite launch hands the suite an interpreter",
      pathlib.Path(suite["env"].get("ORCH_TEST_PY", "")).is_absolute()
      and pathlib.Path(suite["env"]["ORCH_TEST_PY"]).exists())
# An inherited ORCH_TEST_PY must never leak through — the helper's own selection is the policy.
import os as _os
_os.environ["ORCH_TEST_PY"] = "/nonexistent/stale/python"
d.run_integrate_suite(gtree)
check("B9 inherited ORCH_TEST_PY does not leak into the suite",
      suite["env"].get("ORCH_TEST_PY") != "/nonexistent/stale/python")
# Fail-closed branch: no trusted runtime and no repo venv -> ORCH_TEST_PY stays unset, so the
# strict suite fails loudly rather than certifying a tree it could not test.
real_rt, real_root = d.trusted_test_runtime, d.ROOT
d.trusted_test_runtime = lambda: None
d.ROOT = tmp / "no-venv-root"
d.run_integrate_suite(gtree)
check("B9 no interpreter available leaves ORCH_TEST_PY unset (loud strict failure)",
      "ORCH_TEST_PY" not in suite["env"] and suite["env"].get("ORCH_TEST_STRICT") == "1")
d.trusted_test_runtime, d.ROOT = real_rt, real_root
del _os.environ["ORCH_TEST_PY"]

# Reviewer-model failover (owner decision 2026-07-15). Fires ONLY on the CLI's full structured
# model-not-found envelope (type=result + is_error + api_error_status 404, verdict-bearing bodies
# rejected) AND only when the pinned primary (claude-fable-5) was asked for; one retry on the
# fallback through the identical hardened invocation, both envelopes + exit codes + an escalation
# kept, and lc reviewer_model updated to the model that actually produced the verdict. Every other
# failure stays fail-closed with a single invocation — no error may buy a second reviewer roll.
# The real envelope the installed CLI emits for `--model <bogus>` (captured from CLI 2.1.210):
# nonzero exit + this exact `result` text (the model name is interpolated, so the trigger anchors
# on the model-name-independent phrasing, never the whole string).
notfound = json.dumps({"type": "result", "is_error": True, "api_error_status": 404,
                       "result": "There's an issue with the selected model "
                       "(claude-fable-5). It may not exist or you may not have access to it. "
                       "Run --model to pick a different model."})
# Round-3-review, finding on test discrimination: to prove the JSON-body rejection is load-bearing
# (not masked by the two-phrase requirement), the JSON fixtures must carry BOTH signature phrases.
# `both_phrases` is a plain (non-JSON) string with both → it MUST trigger; wrapping the SAME text as
# a JSON array or JSON string scalar decodes as valid JSON → it MUST be rejected. The only thing
# that differs between the positive control and the two negatives is JSON-encodability, so a passing
# `all(phrases)` alone cannot explain the rejection — only `json.loads(res)` can.
both_phrases = ("issue with the selected model — it may not exist or you may not have access to it")
def env404(result):
    return json.dumps({"type": "result", "is_error": True, "api_error_status": 404, "result": result})
check("failover trigger accepts only the full model-not-found discriminator",
      d.reviewer_model_unavailable(notfound)
      and d.reviewer_model_unavailable(env404(both_phrases))                  # both phrases, non-JSON -> True (control)
      and not d.reviewer_model_unavailable(json.dumps(
          {"is_error": True, "api_error_status": 404}))                      # missing type=result
      and not d.reviewer_model_unavailable(json.dumps(
          {"type": "result", "is_error": True, "api_error_status": 500,
           "result": "There's an issue with the selected model"}))          # wrong status
      and not d.reviewer_model_unavailable(json.dumps(
          {"type": "result", "is_error": True, "api_error_status": 404,
           "result": json.dumps({"verdict": "PASS"})}))                      # verdict-bearing body
      and not d.reviewer_model_unavailable(json.dumps(
          {"type": "result", "is_error": True, "api_error_status": 404,
           "result": ["x"]}))                                                # non-string result
      and not d.reviewer_model_unavailable(json.dumps(
          {"type": "result", "is_error": True, "api_error_status": 404}))    # MISSING result
      and not d.reviewer_model_unavailable(json.dumps(
          {"type": "result", "is_error": True, "api_error_status": 404,
           "result": None}))                                                 # null result
      and not d.reviewer_model_unavailable(json.dumps(
          {"type": "result", "is_error": True, "api_error_status": 404,
           "result": ""}))                                                   # empty result
      and not d.reviewer_model_unavailable(json.dumps(
          {"type": "result", "is_error": True, "api_error_status": 404,
           "result": "The requested resource was not found"}))              # unrelated 404 string
      and not d.reviewer_model_unavailable(env404("There's an issue with the selected model"))
                                                                             # only ONE phrase -> all() rejects
      and not d.reviewer_model_unavailable(env404(json.dumps([both_phrases])))
                                                                             # JSON array w/ BOTH phrases -> json.loads rejects
      and not d.reviewer_model_unavailable(env404(json.dumps(both_phrases)))
                                                                             # JSON string scalar w/ BOTH phrases -> json.loads rejects
      and not d.reviewer_model_unavailable(env404("42"))                     # JSON number scalar
      and not d.reviewer_model_unavailable("not json")
      and not d.reviewer_model_unavailable(""))

d.ESCALATIONS = tmp / "escalations"
vschema = {"type": "object", "properties": {"schema_version": {"const": "rv1"}}}
d._verdict_schema_for_attempt = lambda att: vschema
good_verdict = {"spec_digest": "d" * 64, "base_sha": "b" * 40, "worker_commit": "c" * 40,
                "schema_version": "rv1", "verdict": "PASS",
                "criteria": [{"id": "C1", "result": "MET"}], "scope_finding": "in scope",
                "regression_finding": "n/a", "security_findings": "none"}
# R71: the failover pair and CLI alias map now come frozen from launch.json (sourced from
# scripts/models.json at launch); review() reads only these lc fields, never a module constant.
lc69 = {"worktree": str(repo), "base_sha": "b" * 40, "spec_digest": "d" * 64,
        "reviewer_model": "claude-fable-5", "reviewer_effort": "high",
        "reviewer_failover_trigger": "claude-fable-5",
        "reviewer_fallback_model": "claude-opus-4-8",
        "cli_aliases": {"claude-fable-5": "fable"}}
FALLBACK = lc69["reviewer_fallback_model"]

calls = []; cwds = []
def failover_run(cmd, **kw):
    calls.append(cmd); cwds.append(kw.get("cwd"))
    if len(calls) == 1:
        return subprocess.CompletedProcess(cmd, 1, stdout=notfound, stderr="model gone")
    return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(
        {"result": json.dumps(good_verdict)}), stderr="")
d.run = failover_run
att69 = tmp / "attempts" / "SPEC-901" / "1"; (att69 / "raw").mkdir(parents=True)
verdict, raw = d.review(att69, "SPEC-901", lc69, "c" * 40)
check("failover: 404 on the primary triggers exactly one fallback invocation", len(calls) == 2)
check("failover: end-to-end valid PASS verdict is ACCEPTED from the fallback",
      verdict is not None and verdict.get("verdict") == "PASS")
check("failover: primary then fallback model asked for, in that order",
      calls[0][calls[0].index("--model") + 1] == "fable"
      and calls[1][calls[1].index("--model") + 1] == FALLBACK)
check("failover: lc reviewer_model now names the model that produced the verdict",
      lc69["reviewer_model"] == FALLBACK)
check("failover: fallback invocation carries identical flags except the model",
      [a for a in calls[0] if a not in ("fable",)]
      == [a for a in calls[1] if a not in (FALLBACK,)])
check("failover: both invocations ran from a neutral cwd outside the repo",
      all(c and not pathlib.Path(c).resolve().is_relative_to(d.ROOT.resolve()) for c in cwds))
fo = json.loads((att69 / "raw" / "reviewer-failover.json").read_text())
check("failover: audit record has both models and BOTH invocations' exit codes + stderr",
      fo["from_model"] == "claude-fable-5" and fo["to_model"] == FALLBACK
      and fo["primary_returncode"] == 1 and "model gone" in fo["primary_stderr_tail"]
      and fo["fallback_returncode"] == 0 and fo["fallback_stderr_tail"] == "")
check("failover: both envelopes and an escalation are durable",
      (att69 / "raw" / "review-envelope-primary.json").read_text() == notfound
      and (att69 / "raw" / "review-envelope.json").read_text() != notfound
      and any(d.ESCALATIONS.iterdir()))

# A FAILING fallback (primary 404 → fallback itself exits nonzero) must still be fail-closed AND
# leave both invocations' outcomes in the audit record — the earlier version recorded only the
# primary, silently losing the fallback's return code and stderr.
calls = []
def failing_fallback_run(cmd, **kw):
    calls.append(cmd)
    if len(calls) == 1:
        return subprocess.CompletedProcess(cmd, 1, stdout=notfound, stderr="model gone")
    return subprocess.CompletedProcess(cmd, 7, stdout="", stderr="fallback exploded")
d.run = failing_fallback_run
lc73 = dict(lc69, reviewer_model="claude-fable-5")
att73 = tmp / "attempts" / "SPEC-905" / "1"; (att73 / "raw").mkdir(parents=True)
verdict, raw = d.review(att73, "SPEC-905", lc73, "c" * 40)
fo73 = json.loads((att73 / "raw" / "reviewer-failover.json").read_text())
check("failover: a failing fallback is fail-closed with both outcomes recorded",
      verdict is None and len(calls) == 2 and lc73["reviewer_model"] == FALLBACK
      and fo73["primary_returncode"] == 1 and "model gone" in fo73["primary_stderr_tail"]
      and fo73["fallback_returncode"] == 7 and "fallback exploded" in fo73["fallback_stderr_tail"])

calls = []
def error_run(cmd, **kw):
    calls.append(cmd)
    return subprocess.CompletedProcess(cmd, 1, stdout=json.dumps(
        {"type": "result", "is_error": True, "api_error_status": 500, "result": "x"}), stderr="")
d.run = error_run
lc70 = dict(lc69, reviewer_model="claude-fable-5")
att70 = tmp / "attempts" / "SPEC-902" / "1"; (att70 / "raw").mkdir(parents=True)
verdict, raw = d.review(att70, "SPEC-902", lc70, "c" * 40)
check("failover: non-404 reviewer error stays fail-closed, single invocation, model untouched",
      verdict is None and len(calls) == 1 and lc70["reviewer_model"] == "claude-fable-5"
      and not (att70 / "raw" / "reviewer-failover.json").exists())

calls = []
def notfound_run(cmd, **kw):
    calls.append(cmd)
    return subprocess.CompletedProcess(cmd, 1, stdout=notfound, stderr="")
d.run = notfound_run
lc71 = dict(lc69, reviewer_model=FALLBACK)
att71 = tmp / "attempts" / "SPEC-903" / "1"; (att71 / "raw").mkdir(parents=True)
verdict, raw = d.review(att71, "SPEC-903", lc71, "c" * 40)
check("failover: 404 on a non-primary model does not retry (no failover-of-the-failover)",
      verdict is None and len(calls) == 1
      and not (att71 / "raw" / "reviewer-failover.json").exists())

# R71 round-2 review: a legacy launch record (predates the models config, so no trigger/
# fallback/alias fields) keeps EXACTLY the behavior it was launched under — the shipped Fable
# CLI alias and the shipped Fable→Opus retirement retry. An in-flight attempt crossing the
# upgrade is neither stranded (unaliased --model) nor stripped of its failover.
calls = []
d.run = failover_run
lc74 = {"worktree": str(repo), "base_sha": "b" * 40, "spec_digest": "d" * 64,
        "reviewer_model": "claude-fable-5", "reviewer_effort": "high"}
att74 = tmp / "attempts" / "SPEC-908" / "1"; (att74 / "raw").mkdir(parents=True)
verdict, raw = d.review(att74, "SPEC-908", lc74, "c" * 40)
check("legacy launch record keeps the shipped alias and Fable→Opus failover",
      verdict is not None and verdict.get("verdict") == "PASS" and len(calls) == 2
      and calls[0][calls[0].index("--model") + 1] == "fable"
      and calls[1][calls[1].index("--model") + 1] == "claude-opus-4-8"
      and lc74["reviewer_model"] == "claude-opus-4-8"
      and (att74 / "raw" / "reviewer-failover.json").exists())

# Owner-extension round 1: a PARTIAL set of frozen fields is a corrupt record, not a legacy one —
# review() refuses before invoking any reviewer, mixing nothing with the legacy defaults.
calls = []
d.run = failover_run
lc75 = {"worktree": str(repo), "base_sha": "b" * 40, "spec_digest": "d" * 64,
        "reviewer_model": "claude-fable-5", "reviewer_effort": "high",
        "cli_aliases": {"claude-fable-5": "fable"}}   # aliases present, trigger/fallback missing
att75 = tmp / "attempts" / "SPEC-909" / "1"; (att75 / "raw").mkdir(parents=True)
verdict, raw = d.review(att75, "SPEC-909", lc75, "c" * 40)
check("partial frozen fields are a corrupt record: no verdict, zero reviewer invocations",
      verdict is None and len(calls) == 0 and "partial" in raw
      and not (att75 / "raw" / "reviewer-failover.json").exists())

# Deadline honesty: the timeout prefix is recomputed per invocation, so a fallback whose budget
# was burned by the failing primary is REFUSED, not started with a stale allowance.
calls = []
d.run = notfound_run
remaining = [100, 0]
real_rcs = d.remaining_ceiling_s
d.remaining_ceiling_s = lambda ts: remaining.pop(0)
lc72 = dict(lc69, reviewer_model="claude-fable-5", deadline_ts=4102444800.0)
att72 = tmp / "attempts" / "SPEC-904" / "1"; (att72 / "raw").mkdir(parents=True)
verdict, raw = d.review(att72, "SPEC-904", lc72, "c" * 40)
d.remaining_ceiling_s = real_rcs
fo72 = json.loads((att72 / "raw" / "reviewer-failover.json").read_text())
check("failover: exhausted deadline refuses the fallback invocation (fail closed)",
      verdict is None and len(calls) == 1 and "deadline exhausted" in raw
      and calls[0][:1] == ["timeout"]
      # the refused fallback is still recorded — primary outcome kept, refusal captured, no bogus
      # fallback_returncode implying an invocation that never ran.
      and fo72["primary_returncode"] == 1 and "deadline exhausted" in fo72["fallback_refused"]
      and "fallback_returncode" not in fo72)

# review.json provenance (round-3 finding 2): the canonical record binds the EFFECTIVE reviewer
# model (post-failover) through the single tested writer used by the dispatch pipeline. Passing the
# fallback model proves the recorded attribution follows the model that produced the verdict.
attp = tmp / "attempts" / "SPEC-906" / "1"; (attp / "raw").mkdir(parents=True)
d.write_review_record(attp, dict(good_verdict), FALLBACK)
rec = json.loads((attp / "review.json").read_text())
check("review.json binds effective_reviewer_model = the model that produced the verdict",
      rec["effective_reviewer_model"] == FALLBACK and rec["verdict"] == "PASS"
      # the writer copies the verdict — the reviewer's own object is not mutated with our key.
      and "effective_reviewer_model" not in good_verdict)
attn = tmp / "attempts" / "SPEC-907" / "1"; (attn / "raw").mkdir(parents=True)
d.write_review_record(attn, None, FALLBACK)
check("review.json for a null verdict is an empty record, no bogus attribution",
      (attn / "review.json").read_text().strip() == "{}")

sys.exit(1 if fails else 0)
PY
echo "PASS dispatch_fail_closed.sh"
