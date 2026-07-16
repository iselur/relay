#!/usr/bin/env bash
# R73 Job 3: subagent worker mode (owner simplification 2026-07-16). Claude-vendor workers BUILD
# inside the orchestrator session; `dispatch continue` runs the ONE shared grading half. This
# proves: the registry/mode surface; mode freezing at resolution; mode↔vendor consistency
# refusals; launch reaching awaiting_build with NO unit and honest trust_domain provenance; the
# receipt-gated continue and its lock-spanning claim (cancel/reconcile cannot interleave); the
# error_timeout deadline contract (continue and reconcile); ordinary cancellation of a pending
# BUILD; _grade's never-overwrite state guard; the shared grading half from SPEC_BLOCKED through
# no-changes to a synthetic passed_pr_opened; await/health treating awaiting_build as
# pending-by-design; and the codex worker prompt surviving the factoring byte-identically.
# Same box-only skip contract as tests/dispatch_fail_closed.sh (venv-needing self-test).
set -uo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_subagent_worker.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import contextlib, hashlib, importlib.util, io, json, os, pathlib, subprocess, sys, tempfile, time

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

# ---- adapter surface -----------------------------------------------------------------------
w = va.get_worker_adapter("claude")
check("claude worker adapter mode is subagent", va.worker_mode("claude") == "subagent")
raw = pathlib.Path(tempfile.mkdtemp())
check("last message absent reads empty (continue refuses upstream)",
      w.recover_last_message(raw, True) == "")
(raw / "worker-last-message.txt").write_text("done, all tests green")
check("last message reads the orchestrator-written file (both isolation flags)",
      w.recover_last_message(raw, True) == "done, all tests green"
      and w.recover_last_message(raw, False) == "done, all tests green")
check("classify_error is always completion — no CLI vocabulary to speak",
      w.classify_error(None, "", raw) is None and w.classify_error(1, "boom", raw) is None)
try:
    va.worker_mode("gemini")
    check("worker_mode unknown vendor raises (fail closed)", False)
except ValueError:
    check("worker_mode unknown vendor raises (fail closed)", True)

# ---- mode freezes at resolution -------------------------------------------------------------
CFG = {"schema_version": "1",
       "roles": {"orchestrator": {"model": "claude-opus-4-8", "effort": "high"},
                 "spec_author": {"model": "gpt-5.6-sol", "effort": "high"},
                 "utility_subagent": {"model": "claude-sonnet-4-6", "effort": "default"},
                 "worker": {"model": "claude-sonnet-4-6", "effort": "high"},
                 "bound_reviewer": {"model": "claude-fable-5", "effort": "high"},
                 "orchestrator_artifact_reviewer": {"model": "gpt-5.6-sol", "effort": "high"}},
       "reviewer_failover": {"trigger_model": "claude-fable-5",
                             "fallback_model": "claude-opus-4-8"},
       "cli_aliases": {"claude-fable-5": "fable"},
       "vendor_map": {"gpt-5.6-luna": "codex", "gpt-5.6-sol": "codex",
                      "claude-fable-5": "claude", "claude-opus-4-8": "claude",
                      "claude-sonnet-4-6": "claude"}}
r = d.resolve_launch_models({}, CFG)
check("claude worker freezes worker_mode=subagent at resolution",
      r["worker_vendor"] == "claude" and r["worker_mode"] == "subagent")
cfg2 = json.loads(json.dumps(CFG)); cfg2["roles"]["worker"]["model"] = "gpt-5.6-luna"
r2 = d.resolve_launch_models({}, cfg2)
check("codex worker freezes worker_mode=external-cli at resolution",
      r2["worker_vendor"] == "codex" and r2["worker_mode"] == "external-cli")
cfg3 = json.loads(json.dumps(CFG)); cfg3["roles"]["worker"]["model"] = "claude-fable-5"
try:
    d.resolve_launch_models({}, cfg3)
    check("claude worker == reviewer model still refuses (self-review)", False)
except SystemExit:
    check("claude worker == reviewer model still refuses (self-review)", True)

# ---- status vocabulary -----------------------------------------------------------------------
check("awaiting_build counts as a LIVE status (claim_slot concurrency, reconcile)",
      "awaiting_build" in d.LIVE and "awaiting_build" not in d.TERMINAL)
check("error_timeout is TERMINAL (await resolves an expired BUILD immediately)",
      "error_timeout" in d.TERMINAL)

# ---- external-CLI pipeline refuses subagent + mismatched records (TERMINAL) -------------------
snap = b"id: SPEC-000\n"
att = pathlib.Path(tempfile.mkdtemp()); (att / "raw").mkdir()
(att / "spec-snapshot.yaml").write_bytes(snap)
digest = hashlib.sha256(snap).hexdigest()
recorded = {}
class _Stop(Exception): pass
def _finish(status, error_class, **kw):
    recorded.clear()
    recorded["status"], recorded["error_class"] = status, error_class
    recorded["detail"] = kw.get("detail", "")
    raise _Stop()
def drive_pipeline(lc):
    try:
        d._run_pipeline("SPEC-000-1", "SPEC-000", 1, att, dict(lc),
                        pathlib.Path("/nonexistent-wt"), att / "raw", _finish)
    except _Stop:
        pass
base_lc = {"spec_digest": digest, "isolation": True, "deadline_ts": time.time() + 3600}
drive_pipeline({**base_lc, "worker_vendor": "claude", "reviewer_vendor": "codex",
                "worker_mode": "subagent"})
check("external-CLI pipeline refuses a frozen subagent record as error_launch (TERMINAL)",
      recorded.get("status") == "error_launch" and recorded["status"] in d.TERMINAL
      and "continue" in recorded.get("detail", ""))
drive_pipeline({**base_lc, "worker_vendor": "claude", "reviewer_vendor": "codex",
                "worker_mode": "external-cli"})
check("claude vendor + external-cli mode is corrupt: error_launch, no worker invoked",
      recorded.get("status") == "error_launch" and "corrupt" in recorded.get("detail", ""))

# ---- patched state/attempt/escalation roots for lifecycle tests -------------------------------
# ESCALATIONS too (round-4 major 1): the race cases below deliberately produce unverified
# teardowns, and the production escalation writer must never plant fabricated incidents in the
# repo's real audit-provenance directory during a test run.
work = pathlib.Path(tempfile.mkdtemp())
d.ATTEMPTS, d.STATE, d.ESCALATIONS = work / "attempts", work / "state", work / "escalations"
AID, SID, N = "SPEC-900-1", "SPEC-900", 1
attd = d.ATTEMPTS / SID / "1"; (attd / "raw").mkdir(parents=True)
(attd / "spec-snapshot.yaml").write_bytes(snap)

def write_lc(**over):
    lc = {"attempt_id": AID, "spec_id": SID, "attempt": N,
          "spec_digest": digest, "spec_snapshot_digest": digest,
          "base_sha": "0" * 40, "branch": f"codex/{AID}", "base_branch": "ready-for-main",
          "worktree": str(work / "wt"), "worker_model": "claude-sonnet-4-6",
          "worker_effort": "high", "reviewer_model": "claude-fable-5",
          "reviewer_effort": "high", "reviewer_failover_trigger": "claude-fable-5",
          "reviewer_fallback_model": "claude-opus-4-8", "cli_aliases": {},
          "worker_vendor": "claude", "reviewer_vendor": "claude", "worker_mode": "subagent",
          "test_command": "true", "approved_scope": ["**"],
          "hard_ceiling_hours": 1.0, "deadline_ts": time.time() + 3600,
          "remediation": None, "isolation": True, "exposure_accepted": False,
          "worker_unit": f"codex-worker-{AID}", "test_unit": f"codex-test-{AID}"}
    lc.update(over)
    (attd / "launch.json").write_text(json.dumps(lc))
    return lc

def state_now():
    return json.loads((d.STATE / f"{SID}.json").read_text())

def set_state(status, **extra):
    d.write_state(SID, {"attempt_id": AID, "spec_id": SID, "attempt": N,
                        "spec_digest": digest, "status": status, **extra})

def run_die(fn, *a):
    """Call a dispatcher command, capturing die()/finish()'s SystemExit code and stdout."""
    try:
        with contextlib.redirect_stdout(io.StringIO()) as out:
            fn(*a)
        return 0, out.getvalue()
    except SystemExit as e:
        return e.code, ""

def write_receipt(model="claude-sonnet-4-6", **over):
    body = {"model": model, "harness_pin": "claude-sonnet-4-6",
            "launched": "2026-07-16T12:00:00Z"}
    body.update(over)
    (attd / "raw" / "subagent-receipt.json").write_text(json.dumps(body))

def clear_raw():
    for f in ("worker-last-message.txt", "subagent-receipt.json"):
        p = attd / "raw" / f
        if p.exists(): p.unlink()

# continue: refuses an external-CLI record
write_lc(worker_mode="external-cli", worker_vendor="codex")
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses an external-CLI attempt (exit 6)", rc == 6)

# continue: refuses a codex-vendor record that claims subagent mode (corrupt)
write_lc(worker_vendor="codex")
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses codex vendor + subagent mode as corrupt (exit 6)", rc == 6)

# continue: refuses a missing last message
write_lc()
clear_raw()
write_receipt()
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses when raw/worker-last-message.txt is absent (exit 6)", rc == 6)

# continue: refuses a missing, malformed, or launch-mismatched receipt
(attd / "raw" / "worker-last-message.txt").write_text("built")
(attd / "raw" / "subagent-receipt.json").unlink()
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses when raw/subagent-receipt.json is absent (exit 6)", rc == 6)
(attd / "raw" / "subagent-receipt.json").write_text("not json")
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses a malformed receipt (exit 6)", rc == 6)
write_receipt(model="claude-opus-4-8")
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses a receipt naming a model other than the frozen worker_model (exit 6)",
      rc == 6)
write_receipt(harness_pin=None)
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses a receipt without the harness_pin string (exit 6)", rc == 6)
write_receipt(harness_pin="")
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses an empty harness_pin — record the pin or 'none' (exit 6)", rc == 6)
write_receipt()

# continue: refuses when state is not awaiting_build (cancel/reconcile won, or double continue)
set_state("running")
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses unless the attempt awaits its BUILD (exit 8)", rc == 8)
set_state("interrupted", error_class="cancelled")
rc, _ = run_die(d.cmd_continue, AID)
check("continue refuses a cancelled attempt — terminal labels are never overwritten (exit 8)",
      rc == 8)

# continue: exhausted deadline is the addendum's terminal error_timeout, no unit started
write_lc(deadline_ts=time.time() - 5)
set_state("awaiting_build")
rc, _ = run_die(d.cmd_continue, AID)
check("continue on an exhausted deadline exits 10 and records TERMINAL error_timeout",
      rc == 10 and state_now()["status"] == "error_timeout"
      and state_now()["error_class"] == d.ERR_TIMEOUT)

# continue: happy path claims the slot and starts the grading unit under ONE lock hold
write_lc()
set_state("awaiting_build")
captured = {}
_orig_run = d.run
def _fake_run(cmd, **kw):
    captured["cmd"] = cmd
    # the state file must ALREADY say running when the unit starts (the started _grade
    # reads its own claim; writing after would race it)
    captured["state_at_start"] = state_now()["status"]
    class R: returncode = 0; stderr = ""
    return R()
d.run = _fake_run
try:
    rc, out = run_die(d.cmd_continue, AID)
finally:
    d.run = _orig_run
check("continue flips awaiting_build->running and prints the attempt id",
      rc == 0 and state_now()["status"] == "running" and AID in out)
check("the claim is durable BEFORE the grading unit starts (no read-back race)",
      captured.get("state_at_start") == "running")
check("continue starts `dispatch _grade <attempt>` in the attempt's own unit",
      captured["cmd"][-2:] == ["_grade", AID]
      and any(a == f"--unit={d.unit_name(SID, N)}" for a in captured["cmd"]))
rc, _ = run_die(d.cmd_continue, AID)
check("a second continue is refused after the claim (exit 8)", rc == 8)

# cancel: ordinary cancellation of a pending BUILD — no outer-unit stop, verified teardown
write_lc()
set_state("awaiting_build")
calls = []
def _fake_run2(cmd, **kw):
    calls.append(list(cmd))
    class R: returncode = 0; stderr = ""
    return R()
_orig_run = d.run; _orig_units = d.attempt_units_remaining
d.run = _fake_run2
d.attempt_units_remaining = lambda aid, outer=None: ([], True)
try:
    rc, out = run_die(d.cmd_cancel, AID)
finally:
    d.run = _orig_run; d.attempt_units_remaining = _orig_units
outer_stops = [c for c in calls if c[:3] == ["systemctl", "--user", "stop"]]
check("cancel of awaiting_build verifies clean (exit 0) and labels cancelled",
      rc == 0 and state_now()["status"] == "interrupted"
      and state_now()["error_class"] == "cancelled")
check("cancel of awaiting_build never stops the nonexistent outer unit", not outer_stops)

# _grade: never overwrites a state another lifecycle operation owns
write_lc()
(attd / "raw" / "worker-last-message.txt").write_text("built")
set_state("interrupted", error_class="cancelled")
res_path = attd / "result.json"
if res_path.exists(): res_path.unlink()
rc, _ = run_die(d._grade, AID)
check("_grade refuses a non-running state without writing anything (exit 8)",
      rc == 8 and state_now()["status"] == "interrupted" and not res_path.exists())

# _grade: refuses an external-CLI record with a TERMINAL result
write_lc(worker_mode="external-cli", worker_vendor="codex")
set_state("running")
rc, _ = run_die(d._grade, AID)
res = json.loads((attd / "result.json").read_text())
check("_grade refuses an external-CLI record as error_launch (TERMINAL result on disk)",
      rc == 1 and res["status"] == "error_launch" and res["status"] in d.TERMINAL)

# _grade: honors SPEC_BLOCKED through the shared grading half
write_lc()
set_state("running")
(attd / "raw" / "worker-last-message.txt").write_text("SPEC_BLOCKED\nimpossible criteria")
rc, _ = run_die(d._grade, AID)
res = json.loads((attd / "result.json").read_text())
check("_grade routes the subagent message through the shared half (spec_blocked recorded)",
      rc == 1 and res["status"] == "spec_blocked"
      and "orchestrator trust domain" in res["isolation"])

# ---- real-git grading: no-changes, then a synthetic BUILD to passed_pr_opened ----------------
def sh(*a, cwd=None, env=None):
    return subprocess.run(a, cwd=cwd, env=env, capture_output=True, text=True)

repo = pathlib.Path(tempfile.mkdtemp()) / "origin.git"
repo.parent.mkdir(parents=True, exist_ok=True)
sh("git", "init", "--bare", "-b", "ready-for-main", str(repo))
wt = work / "wt"
sh("git", "clone", str(repo), str(wt))
# repo-local identity: the dispatcher's own commit (cwd=wt) inherits committer identity from
# config, and a bare CI box has none — without this the E2E case fails only off-box.
sh("git", "config", "user.name", "t", cwd=str(wt))
sh("git", "config", "user.email", "t@t", cwd=str(wt))
genv = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
(wt / "seed.txt").write_text("seed\n")
sh("git", "add", "-A", cwd=str(wt), env=genv)
sh("git", "commit", "-q", "-m", "seed", cwd=str(wt), env=genv)
sh("git", "push", "-q", "-u", "origin", "HEAD:ready-for-main", cwd=str(wt), env=genv)
base_sha = sh("git", "rev-parse", "HEAD", cwd=str(wt)).stdout.strip()
sh("git", "checkout", "-q", "-b", f"codex/{AID}", cwd=str(wt), env=genv)
sh("git", "fetch", "-q", "origin", cwd=str(wt), env=genv)

# no-changes: a clean worktree is failed_worker_error through the shared half
write_lc(base_sha=base_sha, isolation=False, exposure_accepted=True)
set_state("running")
(attd / "raw" / "worker-last-message.txt").write_text("nothing to do")
rc, _ = run_die(d._grade, AID)
res = json.loads((attd / "result.json").read_text())
check("no-changes BUILD records failed_worker_error through the shared half",
      rc == 1 and res["status"] == "failed_worker_error"
      and "no changes" in res.get("detail", ""))

# synthetic BUILD reaching passed_pr_opened: real git/commit/push, heavy gates stubbed at the
# same seams the fail-closed suite uses; asserts commit authorship + PR provenance wording.
(wt / "built.txt").write_text("subagent work\n")
write_lc(base_sha=base_sha, isolation=False, exposure_accepted=True)
set_state("running")
(attd / "raw" / "worker-last-message.txt").write_text("implemented")
(attd / "test-attestation.json").write_text(json.dumps({"attested": True}))
_orig = (d.required_tests, d.run_candidate_test_phases, d.review, d.run)
d.required_tests = lambda: {"required": [], "installed_commit": base_sha}
d.run_candidate_test_phases = lambda *a, **k: {"attested": True, "detail": ""}
verdict = {"verdict": "PASS", "criteria": [], "scope_finding": "none",
           "regression_finding": "none", "security_findings": "none"}
d.review = lambda *a, **k: (verdict, "raw")
prbody = {}
def _run3(cmd, **kw):
    if cmd and cmd[0] == "gh":
        prbody["body"] = cmd[cmd.index("--body") + 1]
        class R: returncode = 0; stdout = "https://github.com/x/pr/1\n"; stderr = ""
        return R()
    return subprocess.run(cmd, capture_output=True, text=True, **{k: v for k, v in kw.items()
                                                                  if k in ("cwd", "env")})
d.run = _run3
try:
    rc, _ = run_die(d._grade, AID)
finally:
    d.required_tests, d.run_candidate_test_phases, d.review, d.run = _orig
res = json.loads((attd / "result.json").read_text())
author = sh("git", "log", "-1", "--format=%an", cwd=str(wt)).stdout.strip()
check("synthetic subagent BUILD reaches passed_pr_opened through the unchanged grading half",
      rc == 0 and res["status"] == "passed_pr_opened"
      and state_now()["status"] == "passed_pr_opened")
check("the orchestrator-packaged commit is authored Worker <frozen model>",
      author == "Worker claude-sonnet-4-6")
check("PR provenance names the orchestrator trust domain, not a sandbox that never ran",
      "orchestrator trust domain" in prbody.get("body", "")
      and "workspace-write" not in prbody.get("body", ""))
check("break-glass PR provenance admits the unisolated test phase, never claims network=off",
      "network=off" not in prbody.get("body", "")
      and "UNISOLATED" in prbody.get("body", ""))
check("an isolated record still claims network=off for tests (and only then)",
      "network=off for tests" in d.pr_body(SID, {**json.loads((attd / 'launch.json').read_text()),
                                                 "isolation": True}, "c" * 40))

# ---- launch: awaiting_build with NO unit, honest provenance ----------------------------------
lwork = pathlib.Path(tempfile.mkdtemp())
d.ATTEMPTS, d.STATE, d.ESCALATIONS = lwork / "attempts", lwork / "state", lwork / "escalations"
d.ATTEMPTS.mkdir(parents=True); d.STATE.mkdir(parents=True)
LSID = "SPEC-901"
spec = {"id": LSID, "title": "t", "risk_class": "low", "test_command": "true",
        "hard_ceiling_hours": 1, "needs_network": False}
approval = {"approved_scope": ["**"], "base_branch": "ready-for-main"}
spec_bytes = json.dumps(spec).encode()
ldigest = hashlib.sha256(spec_bytes).hexdigest()
launch_calls = []
def _run4(cmd, **kw):
    launch_calls.append(list(cmd))
    class R: returncode = 0; stderr = ""; stdout = ""
    return R()
_saved = (d.isolation_available, d.preflight, d.load_model_config, d.remediation_preflight,
          d.run_box_preconditions, d.execution_policy, d.grader_drift, d.git, d.worktree_root,
          d.grant_worker_acl, d.trusted_test_runtime, d.isolated_run, d.run)
d.isolation_available = lambda: True
d.preflight = lambda sid: {"spec": spec, "digest": ldigest, "approval": approval,
                           "spec_bytes": spec_bytes}
d.load_model_config = lambda: CFG
d.remediation_preflight = lambda *a: None
d.run_box_preconditions = lambda att, policy: {}
d.execution_policy = lambda *a, **k: {"required": [], "modes": {}}
d.grader_drift = lambda *a, **k: []
d.git = lambda *a, **k: "e" * 40
lwt = lwork / "worktrees"
d.worktree_root = lambda iso=None: lwt
d.grant_worker_acl = lambda wt: None
d.trusted_test_runtime = lambda: {"python": "/usr/bin/python3", "root": "/opt/x"}
def _iso_probe(*a, **k):
    class R: returncode = 0; stderr = b""
    return R()
d.isolated_run = _iso_probe
d.run = _run4
try:
    rc, out = run_die(d.cmd_launch, LSID)
finally:
    (d.isolation_available, d.preflight, d.load_model_config, d.remediation_preflight,
     d.run_box_preconditions, d.execution_policy, d.grader_drift, d.git, d.worktree_root,
     d.grant_worker_acl, d.trusted_test_runtime, d.isolated_run, d.run) = _saved
lstate = json.loads((d.STATE / f"{LSID}.json").read_text())
llc = json.loads((d.ATTEMPTS / LSID / "1" / "launch.json").read_text())
started_units = [c for c in launch_calls if c and c[0] == "systemd-run"]
check("claude launch ends awaiting_build and prints the attempt id",
      rc == 0 and lstate["status"] == "awaiting_build" and f"{LSID}-1" in out)
check("claude launch starts NO unit", not started_units)
check("launch freezes subagent mode + orchestrator trust_domain provenance",
      llc["worker_mode"] == "subagent" and llc["worker_vendor"] == "claude"
      and llc["trust_domain"] == "orchestrator")
check("launch writes the BUILD prompt for the orchestrator's subagent",
      (d.ATTEMPTS / LSID / "1" / "raw" / "worker-prompt.txt").exists())

# await/health/reconcile on the pending BUILD
rc, out = run_die(d.cmd_await, f"{LSID}-1")
check("await says awaiting_build and exits 3 (neither pass nor failure)", rc == 3)
rc, out = run_die(d.cmd_health, f"{LSID}-1")
check("health reports not-applicable for awaiting_build", rc == 0)
_orig_units2 = d._list_codex_units
d._list_codex_units = lambda: ([], True)
try:
    rc, out = run_die(d.cmd_reconcile)
    rep = json.loads(out)
    row = [r for r in rep["reconciled"] if r.get("attempt_id") == f"{LSID}-1"][0]
    check("reconcile keeps a fresh awaiting_build pending (no unit by design)",
          row.get("status") == "awaiting_build"
          and json.loads((d.STATE / f"{LSID}.json").read_text())["status"] == "awaiting_build")
    # deterministic interleavings (round-2 blocking 1): the locked CAS must SKIP, never
    # overwrite, when another lifecycle operation moved the state between the unlocked scan
    # and the lock — simulated by flipping the state from inside the locked re-read.
    llc["deadline_ts"] = time.time() - 5
    (d.ATTEMPTS / LSID / "1" / "launch.json").write_text(json.dumps(llc))
    _orig_read = d.read_state
    def _cancel_wins(spec_id):
        st = _orig_read(spec_id)
        if spec_id == LSID and st and st.get("status") == "awaiting_build":
            return {**st, "status": "interrupted", "error_class": "cancelled"}
        return st
    d.read_state = _cancel_wins
    try:
        rc, out = run_die(d.cmd_reconcile)
    finally:
        d.read_state = _orig_read
    rep = json.loads(out)
    row = [r for r in rep["reconciled"] if r.get("attempt_id") == f"{LSID}-1"][0]
    check("reconcile SKIPS an expired awaiting_build when a cancel won the lock first",
          "skipped" in row.get("note", "")
          and json.loads((d.STATE / f"{LSID}.json").read_text())["status"] == "awaiting_build")
    rc, out = run_die(d.cmd_reconcile)
    rep = json.loads(out)
    row = [r for r in rep["reconciled"] if r.get("attempt_id") == f"{LSID}-1"][0]
    check("reconcile expires awaiting_build to TERMINAL error_timeout at the frozen deadline",
          row.get("to") == "error_timeout"
          and json.loads((d.STATE / f"{LSID}.json").read_text())["status"] == "error_timeout")
    # dead-unit relabel: a continue whose unit becomes visible between the unlocked scan and
    # the locked recheck is a LIVE attempt — reconcile must skip it and leave 'running' alone.
    d.write_state(LSID, {"attempt_id": f"{LSID}-1", "spec_id": LSID, "attempt": 1,
                         "spec_digest": ldigest, "status": "running",
                         "unit": d.unit_name(LSID, 1)})
    flips = {"n": 0}
    _orig_active = d.unit_active
    def _appears_late(unit):
        flips["n"] += 1
        return flips["n"] > 1   # first (unlocked) check: gone; locked recheck: active
    d.unit_active = _appears_late
    try:
        rc, out = run_die(d.cmd_reconcile)
    finally:
        d.unit_active = _orig_active
    rep = json.loads(out)
    row = [r for r in rep["reconciled"] if r.get("attempt_id") == f"{LSID}-1"][0]
    check("reconcile skips a running claim whose unit appeared between scan and locked recheck",
          "skipped" in row.get("note", "")
          and json.loads((d.STATE / f"{LSID}.json").read_text())["status"] == "running")
    # and a unit that is STILL gone under the lock is relabeled + torn down as before
    _orig_teardown = d.teardown_attempt
    d.unit_active = lambda unit: False
    d.teardown_attempt = lambda aid, outer, **k: {"slice": "s", "outer_stop_rc": 0,
                                                  "slice_stop_rc": 0, "remaining_units": [],
                                                  "query_ok": True, "verified": True}
    try:
        rc, out = run_die(d.cmd_reconcile)
    finally:
        d.unit_active = _orig_active; d.teardown_attempt = _orig_teardown
    rep = json.loads(out)
    row = [r for r in rep["reconciled"] if r.get("attempt_id") == f"{LSID}-1"][0]
    check("reconcile still relabels+tears down a confirmed-dead unit (interrupted, verified)",
          row.get("to") == "interrupted" and row.get("teardown_verified") is True
          and json.loads((d.STATE / f"{LSID}.json").read_text())["status"] == "interrupted")
    # round-3 blocking 1: a fresh attempt that claims the spec DURING teardown must not have its
    # claim overwritten by the post-teardown detail append — the append is a locked CAS on our
    # own interrupted relabel of the SAME attempt id.
    d.write_state(LSID, {"attempt_id": f"{LSID}-1", "spec_id": LSID, "attempt": 1,
                         "spec_digest": ldigest, "status": "running",
                         "unit": d.unit_name(LSID, 1)})
    def _teardown_and_new_claim(aid, outer, **k):
        # unverified teardown => non-empty detail note; meanwhile attempt 2 claims the spec
        d.write_state(LSID, {"attempt_id": f"{LSID}-2", "spec_id": LSID, "attempt": 2,
                             "spec_digest": ldigest, "status": "launching",
                             "unit": d.unit_name(LSID, 2)})
        return {"slice": "s", "outer_stop_rc": 0, "slice_stop_rc": 0,
                "remaining_units": ["ghost.service"], "query_ok": True, "verified": False}
    d.unit_active = lambda unit: False
    d.teardown_attempt = _teardown_and_new_claim
    try:
        rc, out = run_die(d.cmd_reconcile)
    finally:
        d.unit_active = _orig_active; d.teardown_attempt = _orig_teardown
    fresh = json.loads((d.STATE / f"{LSID}.json").read_text())
    check("a fresh claim during teardown survives — the detail append skips foreign state",
          fresh["attempt_id"] == f"{LSID}-2" and fresh["status"] == "launching"
          and "ESCALATED" not in fresh.get("detail", ""))
    # and when the state IS still ours, the unverified-teardown note lands via the same CAS
    d.write_state(LSID, {"attempt_id": f"{LSID}-1", "spec_id": LSID, "attempt": 1,
                         "spec_digest": ldigest, "status": "running",
                         "unit": d.unit_name(LSID, 1)})
    d.unit_active = lambda unit: False
    d.teardown_attempt = lambda aid, outer, **k: {"slice": "s", "outer_stop_rc": 0,
                                                  "slice_stop_rc": 0,
                                                  "remaining_units": ["ghost.service"],
                                                  "query_ok": True, "verified": False}
    try:
        rc, out = run_die(d.cmd_reconcile)
    finally:
        d.unit_active = _orig_active; d.teardown_attempt = _orig_teardown
    mine = json.loads((d.STATE / f"{LSID}.json").read_text())
    check("an unverified teardown's note appends onto our own interrupted relabel",
          mine["attempt_id"] == f"{LSID}-1" and mine["status"] == "interrupted"
          and "ESCALATED" in mine.get("detail", ""))
finally:
    d._list_codex_units = _orig_units2

# ---- codex worker prompt is byte-identical through the factoring -----------------------------
lc_prompt = {"spec_digest": digest, "spec_snapshot_digest": digest,
             "remediation": {"remediation_number": 1, "limit": 2, "of_attempt": 1,
                             "findings": {"f": ["x"]}}}
expected = (
    "Implement this spec. Modify only in-scope paths. Run the test command until it exits 0. "
    "Leave your changes in the working tree; do NOT commit or push — the orchestrator commits "
    "your work.\n"
    "Inspect relevant code and tests before editing. For non-trivial tasks, maintain a "
    "concise, revisable implementation checklist covering intended files and verification; "
    "skip it for trivial tasks.\n"
    "Implement the simplest, cleanest solution that satisfies the spec — no abstractions or "
    "configurability beyond what the spec designs. Keep the diff surgical: touch no adjacent "
    "code, comments, or formatting; match the existing style; remove only what your own "
    "change orphaned. State non-obvious assumptions in your final report.\n"
    "The approved spec and evidence gates remain binding. If "
    "discovery invalidates the spec or approved scope (impossible acceptance criteria, wrong "
    "test command, inadequate scope), stop and report SPEC_BLOCKED on its own line followed by "
    "the reason — never improvise beyond the spec."
    + "\n\n=== SPEC ===\n" + snap.decode()
    + "\n\n=== REMEDIATION (attempt 2; remediation #1 of max 2) ===\n"
    + "A previous attempt (#1) FAILED. Your job is to address these specific findings — "
    + "nothing else. Stay strictly within the approved scope. If the findings cannot be "
    + "addressed within the spec and scope, report SPEC_BLOCKED.\n"
    + json.dumps({"f": ["x"]}, indent=2))
check("worker prompt is byte-identical to the canonical builder (incl. remediation block)",
      d.worker_prompt_text(att, lc_prompt, 2) == expected)

sys.exit(1 if fails else 0)
PY
rc=$?
if [ $rc -ne 0 ]; then
  echo "FAIL dispatch_subagent_worker.sh"
  exit 1
fi
echo "PASS dispatch_subagent_worker.sh"
