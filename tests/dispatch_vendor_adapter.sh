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

# ---- kimi reviewer units (kimi vendor, slice 2) --------------------------------------------
# Mechanics per .orchestrator/evidence/kimi-probes.md: argv-only prompt (no stdin transport),
# provider alias via cli_aliases, stream-json output, prompt-requested JSON with the shared
# fail-closed parse, and a byte guard at the probe-D E2BIG wall.
km = va.get_reviewer_adapter("kimi")
KAL = {"kimi-k3": "kimi-code/k3"}
argv = km.build_argv("kimi-k3", "max", SCHEMA, KAL, "/x/schema.json", request="REQ")
check("kimi argv: -p one-shot with the request in argv, provider alias, stream-json",
      argv == ["kimi", "-p", "REQ", "-m", "kimi-code/k3", "--output-format", "stream-json"])
check("kimi argv carries no codex exec/effort/sandbox flags and no auto-approval",
      "exec" not in argv and "--sandbox" not in argv and "-y" not in argv
      and not any("model_reasoning_effort" in a for a in argv))
try:
    km.build_argv("kimi-k3", "max", SCHEMA, KAL, "/x/schema.json"); no_req_raises = False
except ValueError:
    no_req_raises = True
check("kimi build_argv without the request refuses (no stdin transport; fail closed)",
      no_req_raises)
# The guard counts UTF-8 BYTES (the E2BIG wall is a byte limit): 2-byte characters at half the
# limit sit exactly ON the boundary and build; one more byte refuses. A character-counting
# guard would not trip until twice as much text — multibyte input discriminates.
at_limit = "é" * (va.KIMI_ARGV_PROMPT_LIMIT // 2)
check("kimi request exactly at the byte guard builds",
      km.build_argv("kimi-k3", "max", SCHEMA, KAL, "/x", request=at_limit)[2] == at_limit)
try:
    km.build_argv("kimi-k3", "max", SCHEMA, KAL, "/x", request=at_limit + "!")
    over_raises = False
except ValueError:
    over_raises = True
check("kimi request one byte over the guard refuses before invocation (never truncated)",
      over_raises)
# Round-1 review of slice 3 (medium 4): an alias map without the required kimi entry refuses
# — the raw relay id must never reach the CLI (probe A: it only accepts provider aliases).
try:
    km.build_argv("kimi-k3", "max", SCHEMA, {}, "/x/schema.json", request="REQ")
    km_noalias_raises = False
except ValueError:
    km_noalias_raises = True
check("kimi reviewer without its required alias entry refuses (fail closed)",
      km_noalias_raises)
# Round-2 review: identity and malformed alias values refuse too — never the raw relay id.
for bad_aliases in ({"kimi-k3": "kimi-k3"}, {"kimi-k3": 7}, {"kimi-k3": "  "}, None):
    try:
        km.build_argv("kimi-k3", "max", SCHEMA, bad_aliases, "/x/s.json", request="REQ")
        check(f"kimi reviewer refuses corrupt alias mapping {bad_aliases!r}", False)
    except ValueError:
        check(f"kimi reviewer refuses corrupt alias mapping {bad_aliases!r}", True)
shaped = km.reviewer_prompt("REQ", SCHEMA)
check("kimi prompt shaping appends the schema and the JSON-only instruction (codex discipline)",
      shaped.startswith("REQ") and "rv1" in shaped and "ONLY one JSON object" in shaped)
kstream = (json.dumps({"role": "user", "content": "ignored"}) + "\n"
           + "not json at all\n"
           + json.dumps({"role": "assistant", "content": "working notes"}) + "\n"
           + json.dumps({"role": "assistant", "content": probe}) + "\n")
check("kimi verdict: bare JSON in the LAST assistant stream line parses",
      km.extract_verdict(kstream) == json.loads(probe))
check("kimi verdict: fenced JSON in the last assistant line falls back to the exact fence pair",
      km.extract_verdict(json.dumps({"role": "assistant",
                                     "content": "```json\n" + probe + "\n```"}))
      == json.loads(probe))
check("kimi verdict: prose-wrapped content is refused",
      km.extract_verdict(json.dumps({"role": "assistant",
                                     "content": "LGTM: " + probe})) is None)
check("kimi verdict: prose after the closing fence is refused",
      km.extract_verdict(json.dumps({"role": "assistant",
                                     "content": "```json\n" + probe + "\n```\nBLOCKING"}))
      is None)
check("kimi verdict: a later assistant line beats an earlier verdict (LAST wins, fail closed)",
      km.extract_verdict(json.dumps({"role": "assistant", "content": probe}) + "\n"
                         + json.dumps({"role": "assistant", "content": "on reflection, FAIL"}))
      is None)
check("kimi verdict: no assistant line at all is refused",
      km.extract_verdict(json.dumps({"role": "system", "content": probe})) is None)
check("kimi verdict: truncated/malformed stream is refused",
      km.extract_verdict('{"role":"assis') is None)
check("kimi verdict: non-dict verdict JSON is refused",
      km.extract_verdict(json.dumps({"role": "assistant", "content": '["PASS"]'})) is None)
check("kimi verdict: non-string assistant content is refused",
      km.extract_verdict(json.dumps({"role": "assistant",
                                     "content": {"verdict": "PASS"}})) is None)
# Round-1 review (major): an earlier PASS must NOT survive trailing damage — the verdict
# source is the last assistant event only while the stream stays valid behind it. All three
# demonstrated stale-PASS sequences refuse; a subsequent VALID assistant event supersedes.
vline = json.dumps({"role": "assistant", "content": probe})
check("kimi verdict: PASS followed by a non-string-content assistant event is refused",
      km.extract_verdict(vline + "\n"
                         + json.dumps({"role": "assistant", "content": None})) is None)
check("kimi verdict: PASS followed by trailing malformed stream data is refused",
      km.extract_verdict(vline + '\n{"role":"assis') is None)
check("kimi verdict: PASS followed by trailing raw prose is refused",
      km.extract_verdict(vline + "\nBLOCKING: unsafe") is None)
check("kimi verdict: a valid assistant event AFTER damage supersedes it (parses)",
      km.extract_verdict('{"broken\n' + vline) == json.loads(probe))
check("kimi verdict: non-assistant events and blank lines after the verdict stay neutral",
      km.extract_verdict(vline + "\n\n"
                         + json.dumps({"role": "tool", "content": "exit 0"}) + "\n")
      == json.loads(probe))

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
# Kimi slice 3: KNOWN_VENDORS now classifies kimi — a full record freezing kimi on either
# side reads back verbatim (deliberately flipping the slice-2 unclassifiable assertion).
check("kimi frozen vendor classifies on either side (dispatcher slice 3)",
      d.lc_frozen_vendor_fields({"worker_vendor": "kimi", "reviewer_vendor": "claude"})
      == {"worker_vendor": "kimi", "reviewer_vendor": "claude"}
      and d.lc_frozen_vendor_fields({"worker_vendor": "codex", "reviewer_vendor": "kimi"})
      == {"worker_vendor": "codex", "reviewer_vendor": "kimi"})
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

# A frozen kimi reviewer vendor through review() itself, end to end (dispatcher slice 3 —
# deliberately flipping the slice-2 refusal): the shaped request rides in argv, the model id
# is alias-translated, and the verdict is recovered from the stream-json envelope.
calls = []
def kimi_ok_run(cmd, **kw):
    calls.append(cmd)
    return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(
        {"role": "assistant", "content": json.dumps(good_verdict)}), stderr="")
d.run = kimi_ok_run
lc94 = dict(lc90, reviewer_vendor="kimi", reviewer_model="kimi-k3",
            cli_aliases={"claude-fable-5": "fable", "kimi-k3": "kimi-code/k3"})
att94 = tmp / "attempts" / "SPEC-954" / "1"; (att94 / "raw").mkdir(parents=True)
verdict, raw = d.review(att94, "SPEC-954", lc94, "c" * 40)
check("kimi-vendor review end to end: request in argv, aliased model, stream verdict accepted",
      verdict is not None and verdict.get("verdict") == "PASS" and len(calls) == 1
      and calls[0][0] == "kimi"
      and calls[0][calls[0].index("-m") + 1] == "kimi-code/k3"
      and "ONLY one JSON object" in calls[0][calls[0].index("-p") + 1])
check("kimi-vendor review: the durable review request IS the argv prompt",
      (att94 / "raw" / "review-request.txt").read_text()
      == calls[0][calls[0].index("-p") + 1])

# An OVERSIZED kimi request through review(): the adapter's argv byte guard refuses before
# any invocation and the refusal (never a truncation) is the phase's recorded outcome.
calls = []
_saved_snap = d.snapshot_spec_text
d.snapshot_spec_text = lambda att, digest: "x" * (va.KIMI_ARGV_PROMPT_LIMIT + 1)
att96 = tmp / "attempts" / "SPEC-956" / "1"; (att96 / "raw").mkdir(parents=True)
verdict, raw = d.review(att96, "SPEC-956", lc94, "c" * 40)
d.snapshot_spec_text = _saved_snap
check("kimi oversized review request refuses before invocation (argv guard, never truncated)",
      verdict is None and len(calls) == 0
      and "refused" in raw and "never truncated" in raw)

# claude/codex reviewer build_argv accept the request keyword and ignore it (their prompts
# ride on stdin) — signature uniformity for the slice-3 call site, zero behavior change.
check("claude/codex build_argv accept request= and ignore it (argv unchanged)",
      cl.build_argv("claude-fable-5", "high", SCHEMA, ALIASES, "/x/s.json", request="R")
      == cl.build_argv("claude-fable-5", "high", SCHEMA, ALIASES, "/x/s.json")
      and cx.build_argv("gpt-5.6-sol", "high", SCHEMA, ALIASES, "/x/s.json", request="R")
      == cx.build_argv("gpt-5.6-sol", "high", SCHEMA, ALIASES, "/x/s.json"))

sys.exit(1 if fails else 0)
PY
echo "PASS dispatch_vendor_adapter.sh"
