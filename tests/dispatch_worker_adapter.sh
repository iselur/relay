#!/usr/bin/env bash
# R73 Job 2: worker vendor adapter (behavior-identical refactor). The role envelope —
# isolation, runtime vetting/pinning, the single attempt deadline, path-safety, commit
# packaging — stays in dispatch.py; the adapter carries only argv, unisolated env, output
# recovery, and error classification. This proves the codex adapter reproduces the
# pre-refactor mechanics EXACTLY (argv and env by full equality, not spot checks), the error
# classes are the dispatcher's own recorded vocabulary, unknown vendors refuse, and the
# module-level worker_codex_runtime() the adapter delegates to remains importable.
# Same box-only skip contract as tests/dispatch_fail_closed.sh (venv-needing self-test).
set -uo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_worker_adapter.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import importlib.util, json, pathlib, sys, tempfile

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

w = va.get_worker_adapter("codex")

# ---- argv: FULL equality with the pre-refactor invocations -------------------------------
WT = "/srv/codexwork/worktrees/SPEC-000-1"
PROMPT = "do the thing"
PREFIX = ["/usr/bin/node", "/opt/codex/bin/codex.js"]
LMP = "/tmp/att/raw/worker-last-message.txt"
common = ["exec", "--cd", WT, "-m", "gpt-5.6-luna",
          "-c", "model_reasoning_effort=high",
          "--skip-git-repo-check", "--json"]
check("isolated argv is byte-identical to the pre-adapter dispatcher",
      w.build_argv("gpt-5.6-luna", "high", WT, PROMPT, isolated=True, argv_prefix=PREFIX)
      == [*PREFIX, *common, "-s", "danger-full-access", PROMPT])
check("unisolated argv is byte-identical (bwrap sandbox on, last-message file)",
      w.build_argv("gpt-5.6-luna", "high", WT, PROMPT, isolated=False,
                   last_message_path=LMP)
      == ["codex", *common, "--sandbox", "workspace-write",
          "--output-last-message", LMP, PROMPT])
av = w.build_argv("gpt-5.6-luna", "high", WT, PROMPT, isolated=True, argv_prefix=PREFIX)
check("model id passes through untranslated (asserted on build_argv OUTPUT, round-1 minor)",
      av[av.index("-m") + 1] == "gpt-5.6-luna")
# Kimi slice 2: build_argv grew an optional cli_aliases keyword (kimi's CLI needs the alias);
# codex accepts it for signature uniformity and IGNORES it — verbatim contract unchanged.
check("codex build_argv accepts cli_aliases and still passes the model id verbatim",
      w.build_argv("gpt-5.6-luna", "high", WT, PROMPT, isolated=True, argv_prefix=PREFIX,
                   cli_aliases={"gpt-5.6-luna": "some-alias"})
      == [*PREFIX, *common, "-s", "danger-full-access", PROMPT])

# ---- unisolated env: FULL equality with the pre-refactor scrubbed dict -------------------
home = pathlib.Path("/home/op")
check("unisolated scrubbed env is identical",
      w.worker_env(home, "op") == {
          "HOME": "/home/op", "USER": "op", "LOGNAME": "op",
          "PATH": "/home/op/.local/bin:/usr/bin:/bin",
          "CODEX_HOME": "/home/op/.codex", "TERM": "dumb", "LANG": "C.UTF-8"})
check("isolated rw extra is exactly the worker's .codex dir",
      w.iso_rw_paths(pathlib.Path("/home/codex-worker")) == ["/home/codex-worker/.codex"])
check("isolated env extra is exactly CODEX_HOME at the pre-refactor value (round-1 major)",
      w.iso_env_extra(pathlib.Path("/home/codex-worker"))
      == {"CODEX_HOME": "/home/codex-worker/.codex"})

# ---- runtime delegation -------------------------------------------------------------------
sentinel = (["x"], [("a", "b")], "entry")
check("runtime() delegates to the injected module-level resolver",
      w.runtime(lambda: sentinel) is sentinel)
check("worker_codex_runtime remains a module-level callable in dispatch.py",
      callable(getattr(d, "worker_codex_runtime", None)))

# ---- output recovery -----------------------------------------------------------------------
raw = pathlib.Path(tempfile.mkdtemp())
(raw / "events.jsonl").write_text(
    json.dumps({"item": {"type": "agent_message", "text": "first"}}) + "\n"
    + "not json at all\n"
    + json.dumps({"item": {"type": "other", "text": "nope"}}) + "\n"
    + json.dumps({"item": {"type": "agent_message", "text": "LAST"}}) + "\n")
check("isolated recovery takes the LAST agent_message, skipping malformed lines",
      w.recover_last_message(raw, True) == "LAST")
check("unisolated recovery with no file is empty, not an error",
      w.recover_last_message(raw, False) == "")
(raw / "worker-last-message.txt").write_text("from file")
check("unisolated recovery reads the CLI-written file",
      w.recover_last_message(raw, False) == "from file")

# ---- error classification: dispatcher vocabulary, pre-refactor decisions ------------------
check("adapter classes ARE the dispatcher's recorded vocabulary",
      (d.ERR_QUOTA, d.ERR_AUTH, d.ERR_SANDBOX, d.ERR_WORKER)
      == ("quota_rate_limit", "auth", "sandbox_denial", "worker_nonzero"))
check("429/rate limit classifies as quota", w.classify_error(1, "HTTP 429", raw) == d.ERR_QUOTA)
check("not-logged-in classifies as auth",
      w.classify_error(1, "Error: Not Logged In", raw) == d.ERR_AUTH)
empty = pathlib.Path(tempfile.mkdtemp())   # no events.jsonl at all
check("nonzero exit + no completed turn + bwrap noise classifies as sandbox",
      w.classify_error(1, "bwrap: loopback failed", empty) == d.ERR_SANDBOX)
check("nonzero exit + no completed turn classifies as generic worker error",
      w.classify_error(1, "boom", empty) == d.ERR_WORKER)
check("zero exit classifies as completion (None)",
      w.classify_error(0, "", empty) is None)
(raw / "events.jsonl").write_text('{"type":"turn.completed"}\n')
check("completed turn + nonzero exit still classifies as completion (pre-refactor rule)",
      w.classify_error(1, "warning noise", raw) is None)

# ---- composed isolated service environment (round-2 major) --------------------------------
# Pin the ACTUAL --setenv set isolated_run hands systemd, not just the adapter method's return:
# every isolated unit keeps the pre-Job-2 base env (incl. CODEX_HOME — a spec test_command may
# read it), and the worker call's adapter env_extra merges to the same single value.
import subprocess as _sp
captured = {}
_orig_run = _sp.run
def _capture(cmd, **kw):
    captured["cmd"] = cmd
    class R: returncode = 0
    return R()
d.subprocess.run = _capture
try:
    d.isolated_run("t-unit", ["true"], cwd=None, rw_paths=[], private_network=True,
                   ceiling_s=1, stdout=None, stderr=None)
    base_setenv = [a for a in captured["cmd"] if a.startswith("--setenv=")]
    check("base isolated env still carries CODEX_HOME (non-worker units unchanged)",
          "--setenv=CODEX_HOME=/home/codex-worker/.codex" in base_setenv
          and "--setenv=HOME=/home/codex-worker" in base_setenv)
    d.isolated_run("w-unit", ["true"], cwd=None, rw_paths=[], private_network=False,
                   ceiling_s=1, stdout=None, stderr=None,
                   env_extra=w.iso_env_extra(pathlib.Path("/home/codex-worker")))
    worker_setenv = [a for a in captured["cmd"] if a.startswith("--setenv=CODEX_HOME=")]
    check("worker call composes to exactly one CODEX_HOME at the pre-refactor value",
          worker_setenv == ["--setenv=CODEX_HOME=/home/codex-worker/.codex"])
finally:
    d.subprocess.run = _orig_run

# ---- adapter-refusal pipeline outcome is TERMINAL (round-3 major) --------------------------
# Drive _run_pipeline to the corrupt-vendor-record refusal with a finish stub and assert the
# RECORDED status is error_launch and a member of TERMINAL — `dispatch await` must resolve the
# refusal immediately, not poll a status that is in neither TERMINAL nor LIVE for 8 hours.
import hashlib
att = pathlib.Path(tempfile.mkdtemp()); (att / "raw").mkdir()
snap = b"id: SPEC-000\n"
(att / "spec-snapshot.yaml").write_bytes(snap)
lc_corrupt = {"spec_digest": hashlib.sha256(snap).hexdigest(), "isolation": True,
              "deadline_ts": 4102444800.0, "worker_vendor": "codex"}   # one vendor key = corrupt
recorded = {}
class _Stop(Exception): pass
def _finish(status, error_class, **kw):
    recorded["status"], recorded["error_class"] = status, error_class
    raise _Stop()
try:
    d._run_pipeline("SPEC-000-1", "SPEC-000", 1, att, lc_corrupt,
                    pathlib.Path("/nonexistent-wt"), att / "raw", _finish)
except _Stop:
    pass
check("corrupt vendor record refusal records error_launch (ERR_LAUNCH)",
      recorded.get("status") == "error_launch" and recorded.get("error_class") == d.ERR_LAUNCH)
check("the recorded refusal status is TERMINAL (await resolves immediately)",
      recorded.get("status") in d.TERMINAL)

# ---- integrate branch-deletion guard (round-1 BLOCKING) -----------------------------------
check("frozen codex/<aid> branch validates for its own attempt",
      d.valid_attempt_branch("codex/SPEC-000-1", "SPEC-000-1"))
check("a future vendor namespace for the same attempt validates",
      d.valid_attempt_branch("claude/SPEC-000-1", "SPEC-000-1"))
for bad in ("main", "ready-for-main", "codex/SPEC-000-2", "codex/SPEC-000-1x",
            "a/b/SPEC-000-1", "SPEC-000-1", "", None, 7, ["codex/SPEC-000-1"]):
    check(f"corrupt/foreign branch value {bad!r} refuses deletion",
          not d.valid_attempt_branch(bad, "SPEC-000-1"))

# ---- kimi worker adapter (kimi vendor, slice 2) --------------------------------------------
# Mechanics per .orchestrator/evidence/kimi-probes.md: -p argv prompt (no exec subcommand),
# -m takes the CLI provider alias from the frozen cli_aliases, stream-json output, -y
# auto-approval (no inner sandbox; the hardened service is the sole confinement), no effort
# flag (K3 carries kimi's own effort model), and NO unisolated mode at all.
kw = va.get_worker_adapter("kimi")
KPREFIX = ["/home/codex-worker/.kimi-code/bin/kimi"]
KAL = {"kimi-k3": "kimi-code/k3"}
check("kimi isolated argv: prefix, -p prompt, provider alias, stream-json, -y",
      kw.build_argv("kimi-k3", "max", WT, PROMPT, isolated=True, argv_prefix=KPREFIX,
                    cli_aliases=KAL)
      == [*KPREFIX, "-p", PROMPT, "-m", "kimi-code/k3", "--output-format", "stream-json", "-y"])
kav = kw.build_argv("kimi-k3", "max", WT, PROMPT, isolated=True, argv_prefix=KPREFIX,
                    cli_aliases=KAL)
check("kimi argv carries no codex flags (exec/--cd/--sandbox/--json/effort) and no worktree path",
      not any(f in kav for f in ("exec", "--cd", "--sandbox", "--json", WT))
      and not any("model_reasoning_effort" in a for a in kav))
# Round-1 review of slice 3 (medium 4): kimi's CLI accepts only its provider aliases, so a
# frozen alias map without the required entry REFUSES — the raw relay id must never reach
# the CLI (deliberately flipping the slice-2 pass-through convention for kimi).
try:
    kw.build_argv("kimi-k3", "max", WT, PROMPT, isolated=True, argv_prefix=KPREFIX)
    kimi_noalias_raises = False
except ValueError:
    kimi_noalias_raises = True
check("kimi without its required alias entry refuses (fail closed, never the raw id)",
      kimi_noalias_raises)
# Round-2 review: an IDENTITY alias (raw id laundered through the map) and a non-string
# alias value must refuse the same way — the alias is a non-empty string DISTINCT from the id.
for bad_aliases in ({"kimi-k3": "kimi-k3"}, {"kimi-k3": 7}, {"kimi-k3": "  "}, "not-a-dict"):
    try:
        kw.build_argv("kimi-k3", "max", WT, PROMPT, isolated=True, argv_prefix=KPREFIX,
                      cli_aliases=bad_aliases)
        check(f"kimi refuses corrupt alias mapping {bad_aliases!r}", False)
    except ValueError:
        check(f"kimi refuses corrupt alias mapping {bad_aliases!r}", True)
try:
    kw.build_argv("kimi-k3", "max", WT, PROMPT, isolated=False, last_message_path=LMP)
    kimi_uniso_raises = False
except ValueError:
    kimi_uniso_raises = True
check("kimi unisolated build refuses (no --cd, no inner sandbox; fail closed)",
      kimi_uniso_raises)
check("kimi unisolated scrubbed env is total and carries no CODEX_HOME analog",
      kw.worker_env(home, "op") == {
          "HOME": "/home/op", "USER": "op", "LOGNAME": "op",
          "PATH": "/home/op/.local/bin:/usr/bin:/bin", "TERM": "dumb", "LANG": "C.UTF-8"})
check("kimi isolated rw extra is exactly the worker's fixed .kimi-code state home",
      kw.iso_rw_paths(pathlib.Path("/home/codex-worker")) == ["/home/codex-worker/.kimi-code"])
check("kimi isolated env extra is empty (no KIMI_HOME-style override exists, probe A)",
      kw.iso_env_extra(pathlib.Path("/home/codex-worker")) == {})
check("kimi runtime() delegates to the injected module-level resolver",
      kw.runtime(lambda: sentinel) is sentinel)
kraw = pathlib.Path(tempfile.mkdtemp())
(kraw / "events.jsonl").write_text(
    json.dumps({"role": "user", "content": "prompt echo"}) + "\n"
    + "garbage line\n"
    + json.dumps({"role": "assistant", "content": "first"}) + "\n"
    + json.dumps({"role": "assistant", "content": "KIMI-LAST"}) + "\n")
check("kimi recovery takes the LAST assistant line, isolated and unisolated alike "
      "(no --output-last-message exists; both paths read the captured stream)",
      kw.recover_last_message(kraw, True) == "KIMI-LAST"
      and kw.recover_last_message(kraw, False) == "KIMI-LAST")
check("kimi recovery with no capture is empty, not an error",
      kw.recover_last_message(pathlib.Path(tempfile.mkdtemp()), True) == "")
check("kimi zero exit classifies as completion (None)",
      kw.classify_error(0, "", kraw) is None)
check("kimi 429/rate-limit classifies as quota (best-effort, probe E unobserved)",
      kw.classify_error(1, "HTTP 429", kraw) == d.ERR_QUOTA)
check("kimi membership signature classifies as auth (probe E)",
      kw.classify_error(1, "unable to verify your membership benefits", kraw) == d.ERR_AUTH)
check("kimi config.invalid classifies as generic worker error (probe E: exit 1)",
      kw.classify_error(1, "error: failed to run prompt: config.invalid: bad model", kraw)
      == d.ERR_WORKER)
check("kimi never classifies sandbox_denial (no inner sandbox exists)",
      kw.classify_error(1, "bwrap: operation not permitted", kraw) == d.ERR_WORKER)

# Kimi slice 3 at the PIPELINE (deliberately flipping the slice-2 unclassifiable refusal):
# a full kimi vendor record now classifies, routes to KimiWorker, and fails closed one gate
# later — at runtime resolution (stubbed absent) via the vendor-selected resolver in the
# live-resolve fallback (no pinned worker_runtime in the record). Still TERMINAL, still
# before any kimi CLI invocation.
lc_kimi = {"spec_digest": hashlib.sha256(snap).hexdigest(), "isolation": True,
           "deadline_ts": 4102444800.0,
           "worker_vendor": "kimi", "reviewer_vendor": "claude"}
_saved_kimi_rt = d.worker_kimi_runtime
d.worker_kimi_runtime = lambda: None
recorded.clear()
try:
    d._run_pipeline("SPEC-000-1", "SPEC-000", 1, att, lc_kimi,
                    pathlib.Path("/nonexistent-wt"), att / "raw", _finish)
except _Stop:
    pass
d.worker_kimi_runtime = _saved_kimi_rt
check("kimi record classifies; absent kimi runtime fails closed TERMINALLY (worker error)",
      recorded.get("status") == "failed_worker_error" and recorded.get("status") in d.TERMINAL
      and recorded.get("error_class") == d.ERR_WORKER)

# Round-1 review of slice 3 (medium 5): a HAND-CARRIED unisolated kimi record (cmd_launch can
# never produce one — it refuses kimi+unisolated before claiming) must land TERMINALLY as
# error_launch through the pipeline's ValueError conversion, never as an uncaught exception
# that strands the attempt. exposure_accepted gets it past T2 to the actual gate under test.
lc_kimi_uniso = {"spec_digest": hashlib.sha256(snap).hexdigest(), "isolation": False,
                 "exposure_accepted": True, "deadline_ts": 4102444800.0,
                 "worker_vendor": "kimi", "reviewer_vendor": "claude",
                 "worker_model": "kimi-k3", "worker_effort": "max",
                 "cli_aliases": {"kimi-k3": "kimi-code/k3"}}
recorded.clear()
try:
    d._run_pipeline("SPEC-000-1", "SPEC-000", 1, att, lc_kimi_uniso,
                    pathlib.Path("/nonexistent-wt"), att / "raw", _finish)
except _Stop:
    pass
check("hand-carried unisolated kimi record refuses TERMINALLY (error_launch, no crash)",
      recorded.get("status") == "error_launch" and recorded.get("status") in d.TERMINAL
      and recorded.get("error_class") == d.ERR_LAUNCH)

# ---- registry ------------------------------------------------------------------------------
check("worker vendor registry is claude+codex+kimi (kimi vendor, slice 2)",
      va.worker_vendors() == ["claude", "codex", "kimi"])
check("codex worker mode is external-cli", va.worker_mode("codex") == "external-cli")
check("kimi worker mode is external-cli", va.worker_mode("kimi") == "external-cli")
try:
    va.get_worker_adapter("gemini")
    check("unknown worker vendor raises (fail closed upstream)", False)
except ValueError:
    check("unknown worker vendor raises (fail closed upstream)", True)

sys.exit(1 if fails else 0)
PY
rc=$?
if [ $rc -ne 0 ]; then
  echo "FAIL dispatch_worker_adapter.sh"
  exit 1
fi
echo "PASS dispatch_worker_adapter.sh"
