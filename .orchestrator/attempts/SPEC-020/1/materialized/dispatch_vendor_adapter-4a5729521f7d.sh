#!/usr/bin/env bash
# R73 Job 1: vendor reviewer adapters. The role envelope (neutral cwd, deadline, nonzero-exit
# refusal, verdict validation) stays in dispatch.py; adapters carry only CLI mechanics. This
# proves adapter selection follows the FROZEN reviewer vendor, codex verdicts extract from the
# probe-proven bare-JSON shape (fence fallback included), a codex error can never buy the
# claude failover retry, and partial vendor records refuse before any invocation.
# Same box-only skip contract as tests/dispatch_fail_closed.sh (venv-needing self-test).
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_vendor_adapter.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import importlib.util, json, pathlib, subprocess, sys, tempfile

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod

d = load("d", "scripts/dispatch.py")
va = load("va", "scripts/vendor_adapters.py")

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

ALIASES = {"claude-fable-5": "fable"}
SCHEMA = {"type": "object", "properties": {"schema_version": {"const": "rv1"}}}

# ---- adapter units -----------------------------------------------------------------------
cl = va.get_reviewer_adapter("claude")
cx = va.get_reviewer_adapter("codex")
argv = cl.build_argv("claude-fable-5", "high", SCHEMA, ALIASES, "/x/schema.json")
check("claude argv: -p json envelope, aliased model, B16 hardening intact",
      argv[:2] == ["claude", "-p"] and "--output-format" in argv
      and argv[argv.index("--model") + 1] == "fable"
      and all(f in argv for f in ("--safe-mode", "--strict-mcp-config",
                                  "--no-session-persistence", "--permission-mode"))
      and argv[argv.index("--tools") + 1] == "")
argv = cx.build_argv("gpt-5.6-sol", "high", SCHEMA, ALIASES, "/att/raw/review-schema.json")
check("codex argv: exec, read-only sandbox, schema file, prompt on stdin",
      argv[:2] == ["codex", "exec"]
      and argv[argv.index("-m") + 1] == "gpt-5.6-sol"
      and argv[argv.index("--sandbox") + 1] == "read-only"
      and argv[argv.index("--output-schema") + 1] == "/att/raw/review-schema.json"
      and argv[-1] == "-")
check("claude prompt shaping is identity (schema rides in argv)",
      cl.reviewer_prompt("REQ", SCHEMA) == "REQ")
shaped = cx.reviewer_prompt("REQ", SCHEMA)
check("codex prompt shaping appends the schema and the JSON-only instruction",
      shaped.startswith("REQ") and "rv1" in shaped and "ONLY one JSON object" in shaped)

good = {"verdict": "PASS", "note": "x"}
check("claude verdict: envelope double-parse",
      cl.extract_verdict(json.dumps({"result": json.dumps(good)})) == good)
check("claude verdict: non-dict inner result is refused",
      cl.extract_verdict(json.dumps({"result": json.dumps(["PASS"])})) is None)
# The codex fixture is the RAW capture from the 2026-07-16 --output-schema probe
# (.orchestrator/evidence/r73-probes.md), not a hand-written expectation.
probe = '{"verdict":"PASS","note":"The arithmetic claim is correct because 2 + 2 equals 4."}'
check("codex verdict: probe-captured bare JSON parses",
      cx.extract_verdict(probe) == json.loads(probe))
check("codex verdict: fenced JSON falls back to fence-strip",
      cx.extract_verdict("```json\n" + probe + "\n```") == json.loads(probe))
check("codex verdict: bare ``` fence also accepted",
      cx.extract_verdict("```\n" + probe + "\n```") == json.loads(probe))
# R73 round-1 review (blocking): the fallback must be an EXACT fence pair — anything looser was
# fail-open (a PASS object with contradictory prose after the closer still extracted).
check("codex verdict: missing closing fence is refused",
      cx.extract_verdict("```json\n" + probe) is None)
check("codex verdict: prose after the closing fence is refused",
      cx.extract_verdict("```json\n" + probe + "\n```\nBLOCKING: unsafe") is None)
check("codex verdict: non-json fence label is refused",
      cx.extract_verdict("```yaml\n" + probe + "\n```") is None)
check("codex verdict: non-dict JSON is refused",
      cx.extract_verdict('["issue"]') is None and cx.extract_verdict('"PASS"') is None)
check("codex verdict: prose is refused", cx.extract_verdict("LGTM, PASS") is None)
try:
    va.get_reviewer_adapter("gemini"); unknown_raises = False
except ValueError:
    unknown_raises = True
check("unknown vendor raises (caller fails closed)", unknown_raises)

# ---- frozen vendor fields ----------------------------------------------------------------
check("both vendor fields present are used verbatim",
      d.lc_frozen_vendor_fields({"worker_vendor": "codex", "reviewer_vendor": "codex"})
      == {"worker_vendor": "codex", "reviewer_vendor": "codex"})
check("zero vendor fields is a legal pre-freezing record (codex worker, claude reviewer)",
      d.lc_frozen_vendor_fields({"reviewer_model": "claude-fable-5"})
      == {"worker_vendor": "codex", "reviewer_vendor": "claude"})
check("exactly one vendor field is corrupt (None)",
      d.lc_frozen_vendor_fields({"worker_vendor": "codex"}) is None)
# R73 round-1 review (medium): presence alone let a corrupt worker_vendor ride along while
# routing happened on reviewer_vendor — BOTH frozen values must be known vendors.
check("unknown worker_vendor in a full record is corrupt (None)",
      d.lc_frozen_vendor_fields({"worker_vendor": "gemini", "reviewer_vendor": "codex"}) is None)
check("unknown reviewer_vendor in a full record is corrupt (None)",
      d.lc_frozen_vendor_fields({"worker_vendor": "codex", "reviewer_vendor": "gemini"}) is None)
cfg = d.load_model_config()
r = d.resolve_launch_models({"worker_model": "gpt-5.6-luna",
                             "reviewer_model": "gpt-5.6-sol"}, cfg)
check("resolver freezes both vendors from vendor_map",
      r["worker_vendor"] == "codex" and r["reviewer_vendor"] == "codex")

# ---- end-to-end through review() ---------------------------------------------------------
tmp = pathlib.Path(tempfile.mkdtemp())
repo = tmp / "repo"; repo.mkdir()
d.ESCALATIONS = tmp / "escalations"
d.git = lambda *a, **k: "diff --git a/x b/x"
d.snapshot_spec_text = lambda att, digest: "id: SPEC-950"
vschema = {"type": "object", "properties": {"schema_version": {"const": "rv1"}}}
d._verdict_schema_for_attempt = lambda att: vschema
good_verdict = {"spec_digest": "d" * 64, "base_sha": "b" * 40, "worker_commit": "c" * 40,
                "schema_version": "rv1", "verdict": "PASS",
                "criteria": [{"id": "C1", "result": "MET"}], "scope_finding": "in scope",
                "regression_finding": "n/a", "security_findings": "none"}

# R73 round-2 review (blocking): the adapter module is pinned at dispatcher import — review()
# consults the pin, never the disk, so a mid-attempt installation cannot swap the adapter.
check("vendor adapters pinned at dispatcher import",
      d.VENDOR_ADAPTERS is not None and hasattr(d.VENDOR_ADAPTERS, "get_reviewer_adapter"))

# A codex-vendor bound review, end to end: bare-JSON verdict accepted, schema file durable.
calls = []
def codex_ok_run(cmd, **kw):
    calls.append(cmd)
    return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(good_verdict), stderr="")
d.run = codex_ok_run
lc90 = {"worktree": str(repo), "base_sha": "b" * 40, "spec_digest": "d" * 64,
        "reviewer_model": "gpt-5.6-sol", "reviewer_effort": "high",
        "reviewer_failover_trigger": "claude-fable-5",
        "reviewer_fallback_model": "claude-opus-4-8",
        "cli_aliases": {"claude-fable-5": "fable"},
        "worker_vendor": "codex", "reviewer_vendor": "codex"}
att90 = tmp / "attempts" / "SPEC-950" / "1"; (att90 / "raw").mkdir(parents=True)
verdict, raw = d.review(att90, "SPEC-950", lc90, "c" * 40)
check("codex-vendor review: adapter argv used, bare-JSON PASS verdict accepted",
      verdict is not None and verdict.get("verdict") == "PASS" and len(calls) == 1
      and calls[0][calls[0].index("--output-schema") - 2] != "claude"
      and "codex" in calls[0][:3])
check("codex-vendor review: schema file written durably under raw/",
      json.loads((att90 / "raw" / "review-schema.json").read_text()) == vschema)
check("codex-vendor review: shaped prompt (schema appended) is the durable review request",
      "ONLY one JSON object" in (att90 / "raw" / "review-request.txt").read_text())

# review() consults the PIN, not the disk: with the pin gone, no reviewer is ever invoked.
att95 = tmp / "attempts" / "SPEC-955" / "1"; (att95 / "raw").mkdir(parents=True)
_saved_pin, d.VENDOR_ADAPTERS = d.VENDOR_ADAPTERS, None
_saved_err, d.VENDOR_ADAPTERS_ERR = d.VENDOR_ADAPTERS_ERR, "simulated load failure"
calls_before = len(calls)
v95, raw95 = d.review(att95, "SPEC-955", lc90, "c" * 40)
d.VENDOR_ADAPTERS, d.VENDOR_ADAPTERS_ERR = _saved_pin, _saved_err
check("missing adapter pin fails closed without invoking any reviewer",
      v95 is None and "failed to load at dispatcher start" in raw95
      and len(calls) == calls_before)

# A codex reviewer error whose stdout MIMICS the claude 404 envelope must not buy a retry.
notfound_mimic = json.dumps({"type": "result", "is_error": True, "api_error_status": 404,
                             "result": "There's an issue with the selected model "
                             "(x). It may not exist or you may not have access to it."})
calls = []
def codex_err_run(cmd, **kw):
    calls.append(cmd)
    return subprocess.CompletedProcess(cmd, 1, stdout=notfound_mimic, stderr="err")
d.run = codex_err_run
lc91 = dict(lc90, reviewer_model="claude-fable-5")   # even the trigger model id cannot arm it
att91 = tmp / "attempts" / "SPEC-951" / "1"; (att91 / "raw").mkdir(parents=True)
verdict, raw = d.review(att91, "SPEC-951", lc91, "c" * 40)
check("codex-vendor error never fires the claude failover (single call, no retry, no verdict)",
      verdict is None and len(calls) == 1
      and not (att91 / "raw" / "reviewer-failover.json").exists())

# Partial vendor fields: corrupt record, zero invocations.
calls = []
d.run = codex_ok_run
lc92 = {k: v for k, v in lc90.items() if k != "worker_vendor"}
att92 = tmp / "attempts" / "SPEC-952" / "1"; (att92 / "raw").mkdir(parents=True)
verdict, raw = d.review(att92, "SPEC-952", lc92, "c" * 40)
check("partial vendor fields refuse before any reviewer invocation",
      verdict is None and len(calls) == 0 and "vendor" in raw)

# A legacy record (no vendor fields at all) still routes to the claude adapter, aliased.
calls = []
def claude_ok_run(cmd, **kw):
    calls.append(cmd)
    return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(
        {"result": json.dumps(good_verdict)}), stderr="")
d.run = claude_ok_run
lc93 = {"worktree": str(repo), "base_sha": "b" * 40, "spec_digest": "d" * 64,
        "reviewer_model": "claude-fable-5", "reviewer_effort": "high"}
att93 = tmp / "attempts" / "SPEC-953" / "1"; (att93 / "raw").mkdir(parents=True)
verdict, raw = d.review(att93, "SPEC-953", lc93, "c" * 40)
check("legacy record routes to the claude adapter with the shipped alias",
      verdict is not None and verdict.get("verdict") == "PASS" and len(calls) == 1
      and calls[0][calls[0].index("--model") + 1] == "fable"
      and calls[0][:2][-1] == "-p")

sys.exit(1 if fails else 0)
PY
echo "PASS dispatch_vendor_adapter.sh"
