#!/usr/bin/env bash
# B6 (audit codex-audit-2026-07-15, report.md #6 / verification.md H6) — regression test for the
# systemd-unit lifecycle bugs and the round-1 review follow-ups:
#
#   Original B6:
#   1. An attempt spawns FIVE unit families (worker, spec test, one per installed test, regression
#      base, regression candidate) but `dispatch cancel` stopped only two hand-picked names, leaving
#      the rest running as orphans after the operator believed the attempt was dead.
#   2. Every phase got a FRESH FULL RuntimeMaxSec ceiling instead of sharing one absolute attempt
#      deadline, so total wall-clock could run to several multiples of the configured hard ceiling.
#
#   Round-1 review (Codex) blocking follow-ups, also covered here:
#   1. remaining_ceiling_s() must REFUSE a phase (return 0) when under the minimum, never grant the
#      floor and let a child outlive the deadline; refusal also applies to candidate-read + the
#      unisolated fallback phases.
#   2. Teardown must stop the PRODUCER (outer pipeline unit) BEFORE the slice, so nothing is launched
#      into a torn-down slice.
#   3. Verification must FAIL CLOSED: a failed list-units query is never read as "no units remain",
#      and a surviving unit escalates rather than warn-and-continues.
#   4. A timeout (outer RuntimeMaxSec firing) must tear down + verify the slice at stop time, not
#      defer to a later reconcile.
#
# Real systemd side effects are unavailable in CI (and undesirable even on the box for a unit test),
# so this is hermetic: the `subprocess` name inside dispatch.py's own namespace is replaced with a
# fake that RECORDS every command and fakes only the systemd/systemctl/sudo family (letting git/bash
# pass through for real), plus an injectable clock for elapsed time. Same box-only skip contract and
# fake style as tests/dispatch_gate4.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${ORCH_TEST_PY:-.venv/bin/python}"
if [ ! -x "$PY" ] || ! "$PY" -c 'import yaml, jsonschema' 2>/dev/null; then
  echo "SKIP dispatch_cancel_teardown.sh: .venv/pyyaml/jsonschema absent (dispatcher self-test runs on the box only, not CI)"
  exit 77   # did NOT run — never a pass (T1/R26)
fi

"$PY" - <<'PY'
import contextlib, importlib.util, inspect, io, json, pathlib, subprocess, tempfile, time as real_time, types

spec = importlib.util.spec_from_file_location("d", "scripts/dispatch.py")
d = importlib.util.module_from_spec(spec); spec.loader.exec_module(d)

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# ------------------------------------------------------------------------------------------------
# The seam: isolated_run() calls `subprocess.run` DIRECTLY (not the d.run() wrapper), and d.run()
# itself bottoms out in `subprocess.run` too, so the single name reaching EVERY systemd invocation
# — systemctl stop / list-units AND systemd-run — is `subprocess` inside dispatch.py's own namespace.
# Rebinding d.subprocess (not the process-wide module) confines the fake to this module: every
# systemd-family command (systemctl / systemd-run / sudo) is recorded and faked (never real systemd),
# and everything else (git, bash) passes through to the real subprocess.run so the git fixtures run.
_real_subprocess_run = subprocess.run
calls = []

# Controllable list-units response so teardown VERIFICATION can be exercised: default is a clean
# empty listing that returns 0; tests flip these to simulate surviving units or a failed query.
fake_list = {"output": "", "rc": 0}
# Controllable return code for `systemctl --user stop <outer>` so the round-3 finding-1 case (a
# FAILED outer-unit stop must NOT verify clean despite the exclusion) can be exercised.
fake_outer_stop = {"rc": 0}

class FakeClock:
    def __init__(self, start): self.now = start
    def time(self): return self.now
    def advance(self, s): self.now += s

clock = FakeClock(1_700_000_000.0)
PHASE_DURATION_S = 40  # simulated wall-clock cost of one systemd-run phase (> MIN_PHASE_CEILING_S)

def _is_systemd_family(cmd):
    head = cmd[0] if cmd else ""
    return head in ("systemctl", "systemd-run") or head == "sudo"

def fake_run(cmd, **kw):
    cmd = list(cmd)
    calls.append(cmd)
    if _is_systemd_family(cmd):
        if "list-units" in cmd:
            return types.SimpleNamespace(returncode=fake_list["rc"], stdout=fake_list["output"], stderr="")
        if cmd[:3] == ["systemctl", "--user", "stop"]:
            return types.SimpleNamespace(returncode=fake_outer_stop["rc"], stdout="", stderr="")
        if "systemd-run" in cmd:
            clock.advance(PHASE_DURATION_S)  # a phase "ran" — the deadline ticks down for real
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")
    if "stdout" not in kw and "stderr" not in kw and "capture_output" not in kw:
        kw.setdefault("capture_output", True)
        kw.setdefault("text", True)
    return _real_subprocess_run(cmd, **kw)

d.subprocess = types.SimpleNamespace(run=fake_run, PIPE=subprocess.PIPE,
                                     STDOUT=subprocess.STDOUT, DEVNULL=subprocess.DEVNULL)
d.time = types.SimpleNamespace(time=clock.time, sleep=real_time.sleep)
# Escalations (finding 3) land in a temp dir, isolated from the real .orchestrator.
d.ESCALATIONS = pathlib.Path(tempfile.mkdtemp()) / "escalations"

def prop(cmd, key):
    for tok in cmd:
        if tok.startswith(f"--property={key}="):
            return tok.split("=", 2)[-1]
    return None

def runtime_max_sec(cmd):
    v = prop(cmd, "RuntimeMaxSec")
    return int(v) if v is not None else None

def slice_of(cmd):
    for tok in cmd:
        if tok.startswith("--slice="):
            return tok.split("=", 1)[1]
    return None

def unit_of(cmd):
    for tok in cmd:
        if tok.startswith("--unit="):
            return tok.split("=", 1)[1]
    return None

def is_sudo_stop(cmd, target):
    return cmd[:2] == ["sudo", "-n"] and "stop" in cmd and cmd[-1] == target

def is_user_stop(cmd, target):
    return cmd[:3] == ["systemctl", "--user", "stop"] and cmd[-1] == target

# ==================================================================================================
# Group A — isolated_run() threads --slice=<attempt slice> into EVERY unit family it is asked to run
# (the single shared implementation point every attempt-owned call site routes through), and omits
# it when no slice_name is given (the two pre-attempt runtime-probe units, which are not attempt-
# owned and correctly stay out of any attempt's slice).
aid = "SPEC-900-1"
families = {
    "worker": f"codex-worker-{aid}",
    "spec-test": f"codex-test-{aid}",
    "installed-test": f"codex-test-{aid}-mystem",
    "regression-base": f"codex-regbase-{aid}",
    "regression-candidate": f"codex-regcand-{aid}",
}
for label, unit in families.items():
    calls.clear()
    d.isolated_run(unit, ["true"], cwd=None, rw_paths=[], private_network=True, ceiling_s=100,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   slice_name=d.attempt_slice(aid))
    cmd = calls[-1]
    check(f"isolated_run({label}): unit is {unit}", unit_of(cmd) == unit)
    check(f"isolated_run({label}): joins the attempt slice", slice_of(cmd) == d.attempt_slice(aid))
    check(f"isolated_run({label}): honors the given ceiling", runtime_max_sec(cmd) == 100)

calls.clear()
d.isolated_run("codex-rtprobe-SPEC-900", ["true"], cwd=None, rw_paths=[], private_network=True,
               ceiling_s=120, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)  # no slice_name
check("isolated_run(no slice_name given): no --slice= flag is emitted",
      slice_of(calls[-1]) is None)

# ==================================================================================================
# Group B — remaining_ceiling_s(): the pure deadline-arithmetic at the center of the fix, including
# the round-1 over-grant fix. Uses the injected clock, never a real sleep.
MIN = d.MIN_PHASE_CEILING_S
d0 = clock.now + 1000
check("remaining_ceiling_s: full window", d.remaining_ceiling_s(d0) == 1000)
clock.advance(900)
check("remaining_ceiling_s: decreases with elapsed time", d.remaining_ceiling_s(d0) == 100)
clock.advance(200)  # now 100s past the deadline
check("remaining_ceiling_s: 0 once the deadline has passed", d.remaining_ceiling_s(d0) == 0)
base = clock.now
check("remaining_ceiling_s: exactly MIN remaining is allowed (returns MIN)",
      d.remaining_ceiling_s(base + MIN) == MIN)
check("remaining_ceiling_s: one second over MIN is allowed", d.remaining_ceiling_s(base + MIN + 1) == MIN + 1)
# THE over-grant fix: under the floor must REFUSE (return 0), never grant the floor.
check("remaining_ceiling_s: 3s left REFUSES (returns 0), never grants the 30s floor",
      d.remaining_ceiling_s(base + 3) == 0)
check("remaining_ceiling_s: one second UNDER MIN refuses (returns 0)",
      d.remaining_ceiling_s(base + MIN - 1) == 0)

# ROUND-2 finding 3 — deadline_timeout_prefix(): the wall-clock cap for phases without a systemd
# RuntimeMaxSec. It must return a coreutils `timeout` prefix carrying the REMAINING seconds, and
# None (refuse) when the deadline is spent — not just a pre-start yes/no.
pfx = d.deadline_timeout_prefix(base + 500)
check("deadline_timeout_prefix: returns a `timeout` prefix carrying remaining seconds",
      pfx[:1] == ["timeout"] and "500" in pfx and "-k" in pfx)
check("deadline_timeout_prefix: caps at the REMAINING time, not a fresh full window",
      d.deadline_timeout_prefix(base + 120)[-1] == "120")
check("deadline_timeout_prefix: None (refuse) when under MIN remains",
      d.deadline_timeout_prefix(base + 3) is None)
check("deadline_timeout_prefix: None (refuse) once the deadline has passed",
      d.deadline_timeout_prefix(base - 10) is None)

# ==================================================================================================
# Group C — run_candidate_test_phases(): a REAL production call site (not a reimplementation),
# driven against a synthetic policy so we control exactly how many isolated_run calls happen.
# Proves (a) each installed-test unit joins the attempt slice, (c) each gets only the time REMAINING
# to the one deadline (strictly decreasing across the loop) not a fresh ceiling, and the over-grant
# refusal: a 3s-to-deadline phase is refused (no unit), never granted the floor.
ctmp = pathlib.Path(tempfile.mkdtemp())
(ctmp / "tests").mkdir()
for name in ("t1.sh", "t2.sh"):
    p = ctmp / "tests" / name
    p.write_text("#!/bin/sh\nexit 0\n"); p.chmod(0o755)
# t3 is candidate-READ (round-1: refusal must reach candidate-read too).
(ctmp / "tests" / "t3.sh").write_text("#!/bin/sh\nexit 0\n"); (ctmp / "tests" / "t3.sh").chmod(0o755)
(ctmp / "tests" / "execution-policy.tsv").write_text(
    "tests/t1.sh\tcandidate-isolated\tsynthetic B6 fixture\n"
    "tests/t2.sh\tcandidate-isolated\tsynthetic B6 fixture\n"
    "tests/t3.sh\tcandidate-read\tsynthetic B6 read fixture\n")
# B4's grader_drift() (now enforced at the top of run_candidate_test_phases) requires every grader
# input — scripts/test + scripts/requirements.txt too — present and committed, or it fails closed.
(ctmp / "scripts").mkdir()
(ctmp / "scripts" / "test").write_text("#!/bin/sh\nexit 0\n"); (ctmp / "scripts" / "test").chmod(0o755)
(ctmp / "scripts" / "requirements.txt").write_text("dummy\n")
d.run(["git", "init", "-q", "-b", "main", str(ctmp)])
d.run(["git", "-C", str(ctmp), "config", "user.email", "t@t"])
d.run(["git", "-C", str(ctmp), "config", "user.name", "t"])
d.run(["git", "-C", str(ctmp), "add", "-A"])
d.run(["git", "-C", str(ctmp), "commit", "-qm", "init"])
installed_commit = d.git("rev-parse", "HEAD", cwd=ctmp)

_orig_ROOT, _orig_EXECUTION_POLICY = d.ROOT, d.EXECUTION_POLICY
_orig_test_runtime_matches = d.test_runtime_matches
_orig_trusted_test_runtime = d.trusted_test_runtime
d.ROOT = ctmp
d.EXECUTION_POLICY = ctmp / "tests" / "execution-policy.tsv"
d.test_runtime_matches = lambda record: True   # bypass the box-specific trusted-runtime probe
d.trusted_test_runtime = lambda: None          # (it also probes ROOT/scripts/requirements.txt)

policy = d.execution_policy(ctmp, installed_commit)   # B4 made commit a required arg
policy["installed_commit"] = installed_commit
catt = ctmp / "att"; (catt / "raw").mkdir(parents=True)
lc = {"execution_policy": policy, "test_unit": f"codex-test-{aid}", "attempt_id": aid,
      "test_runtime": {"root": "/tmp/fake-test-runtime", "python": "/tmp/fake-test-runtime/bin/python"}}

calls.clear()
deadline = clock.now + 300
d.run_candidate_test_phases(lc, ctmp, installed_commit, catt, deadline, [])
test_calls = [c for c in calls if "systemd-run" in c]
check("run_candidate_test_phases: one isolated_run per candidate-isolated test (read runs no unit)",
      len(test_calls) == 2)
check("run_candidate_test_phases: every installed-test unit joins the attempt slice",
      all(slice_of(c) == d.attempt_slice(aid) for c in test_calls))
ceilings = [runtime_max_sec(c) for c in test_calls]
check("run_candidate_test_phases: RuntimeMaxSec strictly decreases across the loop "
      f"(not a fresh ceiling each time) {ceilings}", ceilings[0] > ceilings[1])
check("run_candidate_test_phases: the SAME deadline is spent down, not reset "
      f"(delta == simulated phase cost) {ceilings}", ceilings[0] - ceilings[1] == PHASE_DURATION_S)
# ROUND-2 finding 3 — the candidate-READ phase runs no systemd unit, so it must be wrapped in a
# `timeout` bound to the deadline, not left uncapped once started.
read_runs = [c for c in calls if c[:1] == ["timeout"] and any("t3.sh" in tok for tok in c)]
check("run_candidate_test_phases: the candidate-READ phase is wrapped in a deadline `timeout` (finding 3)",
      len(read_runs) == 1 and "-k" in read_runs[0])

# Over-grant refusal (round-1 finding 1): 3s to the deadline must refuse every remaining phase,
# launching NO unit — not grant the 30s floor.
calls.clear()
near = clock.now + 3
res_near = d.run_candidate_test_phases(lc, ctmp, installed_commit, catt, near, [])
check("run_candidate_test_phases: 3s to deadline REFUSES the phase (no unit launched), not a floor grant",
      not any("systemd-run" in c for c in calls))
near_statuses = [o["status"] for obs in res_near["tests"].values() for o in obs["observations"][-1:]]
check("run_candidate_test_phases: a refused (near-deadline) phase is FAIL, never silently skipped",
      near_statuses and all(s == "FAIL" for s in near_statuses))

# Fully spent deadline: candidate-ISOLATED and candidate-READ both refuse, both logged.
calls.clear()
past_deadline = clock.now - 500
res_past = d.run_candidate_test_phases(lc, ctmp, installed_commit, catt, past_deadline, [])
check("run_candidate_test_phases: refuses to start any phase past a spent deadline (no isolated_run)",
      not any("systemd-run" in c for c in calls))
iso_log = (catt / "raw" / "candidate-isolated-t1.log").read_text()
read_log = (catt / "raw" / "candidate-read-t3.log").read_text()
check("run_candidate_test_phases: candidate-isolated refusal names the exhausted deadline",
      "deadline exhausted" in iso_log)
check("run_candidate_test_phases: candidate-READ refusal ALSO names the exhausted deadline (round-1)",
      "deadline exhausted" in read_log)

d.ROOT, d.EXECUTION_POLICY = _orig_ROOT, _orig_EXECUTION_POLICY
d.test_runtime_matches = _orig_test_runtime_matches
d.trusted_test_runtime = _orig_trusted_test_runtime

# ==================================================================================================
# Group D — run_regression_gate(): the OTHER real production call site, driven against a real temp
# git repo (same fixture shape as tests/dispatch_gate4.sh) with iso=True so it actually reaches
# isolated_run for both the base and candidate runs. Proves both share the attempt slice, the
# candidate run gets less remaining time than the base run (same deadline), and the over-grant
# refusal: with the base run consuming the window, the candidate is refused rather than floor-granted.
rtmp = pathlib.Path(tempfile.mkdtemp())
rrepo = rtmp / "r"
d.run(["git", "init", "-qb", "main", str(rrepo)])
d.run(["git", "-C", str(rrepo), "config", "user.email", "t@t"])
d.run(["git", "-C", str(rrepo), "config", "user.name", "t"])
(rrepo / "calc.py").write_text("def add(a, b):\n    return a - b  # bug\n")
d.run(["git", "-C", str(rrepo), "add", "-A"])
d.run(["git", "-C", str(rrepo), "commit", "-qm", "base(buggy)"])
rbase = d.git("rev-parse", "HEAD", cwd=rrepo)
(rrepo / "calc.py").write_text("def add(a, b):\n    return a + b\n")
(rrepo / "test_reg.py").write_text("from calc import add\nassert add(2, 2) == 4\nprint('ok')\n")
d.run(["git", "-C", str(rrepo), "add", "-A"])
d.run(["git", "-C", str(rrepo), "commit", "-qm", "fix+test"])
rcand = d.git("rev-parse", "HEAD", cwd=rrepo)
raid = "SPEC-901-1"
rcand_wt = rtmp / raid
d.run(["git", "-C", str(rrepo), "worktree", "add", "--quiet", "--detach", str(rcand_wt), rcand])

_orig_wtr, _orig_git, _orig_gwa = d.worktree_root, d.git, d.grant_worker_acl
d.worktree_root = lambda *a, **k: rtmp
def _tgit(*a, **k):
    k.setdefault("cwd", rrepo)
    return _orig_git(*a, **k)
d.git = _tgit
d.grant_worker_acl = lambda wt: None   # not under test here — B6 is the slice/deadline, not ACLs
_orig_run = d.run
def _trun(cmd, **k):
    if cmd[:2] == ["git", "worktree"]:
        k.setdefault("cwd", str(rrepo))
    return _orig_run(cmd, **k)
d.run = _trun

ratt = rtmp / "att"; ratt.mkdir()
rlc = {"regression_command": "python3 test_reg.py", "regression_test_paths": ["test_reg.py"],
       "base_sha": rbase, "attempt_id": raid}

calls.clear()
r_deadline = clock.now + 300
d.run_regression_gate(rlc, rcand_wt, rcand, ratt, iso=True, deadline_ts=r_deadline)
reg_calls = [c for c in calls if "systemd-run" in c]
check("run_regression_gate: exactly base + candidate isolated_run calls", len(reg_calls) == 2)
check("run_regression_gate: both regression units join the attempt slice",
      all(slice_of(c) == d.attempt_slice(raid) for c in reg_calls))
check("run_regression_gate: base unit is codex-regbase-<aid>",
      unit_of(reg_calls[0]) == f"codex-regbase-{raid}")
check("run_regression_gate: candidate unit is codex-regcand-<aid>",
      unit_of(reg_calls[1]) == f"codex-regcand-{raid}")
reg_ceilings = [runtime_max_sec(c) for c in reg_calls]
check(f"run_regression_gate: candidate run gets LESS remaining time than base (same deadline) "
      f"{reg_ceilings}", reg_ceilings[1] < reg_ceilings[0])

# Over-grant refusal: window large enough for base to run but not the candidate afterwards.
calls.clear()
r_deadline2 = clock.now + (MIN + PHASE_DURATION_S // 2)  # base runs, then < MIN left → candidate refused
reg2 = d.run_regression_gate(rlc, rcand_wt, rcand, ratt, iso=True, deadline_ts=r_deadline2)
check("run_regression_gate: base runs but candidate is REFUSED once < MIN remains (not floor-granted)",
      len([c for c in calls if "systemd-run" in c]) == 1
      and reg2["candidate_exit"] is None and "deadline exhausted" in reg2["reason"])

d.worktree_root, d.git, d.grant_worker_acl, d.run = _orig_wtr, _orig_git, _orig_gwa, _orig_run

# ==================================================================================================
# Group E — teardown_attempt(): the shared teardown every ending path uses. Proves producer-first
# ordering (finding 2), the second slice-stop reap, and fail-closed verification (finding 3).
taid = "SPEC-905-1"
tunit = d.unit_name("SPEC-905", 1)
tslice = d.attempt_slice(taid)

calls.clear()
td = d.teardown_attempt(taid, tunit)
def first_idx(pred): return next(i for i, c in enumerate(calls) if pred(c))
outer_i = first_idx(lambda c: is_user_stop(c, tunit))
slice_i = first_idx(lambda c: is_sudo_stop(c, tslice))
check("teardown_attempt: stops the PRODUCER (outer --user unit) BEFORE the slice (finding 2)",
      outer_i < slice_i)
check("teardown_attempt: no member (systemd-run) is launched during teardown",
      not any("systemd-run" in c for c in calls))
check("teardown_attempt: slice is stopped AGAIN after the producer (reap mid-teardown spawns)",
      sum(1 for c in calls if is_sudo_stop(c, tslice)) >= 2)
check("teardown_attempt: verified clean when query ok + nothing remains", td["verified"] is True)

# Finding 3a — a FAILED list-units query must NOT be read as "no units remain".
calls.clear()
fake_list["rc"] = 1
td_q = d.teardown_attempt("SPEC-906-1", d.unit_name("SPEC-906", 1))
check("teardown_attempt: a failed list-units query FAILS CLOSED (not verified)",
      td_q["verified"] is False and td_q["query_ok"] is False)
fake_list["rc"] = 0

# Finding 3b — a surviving unit is reported and not verified.
calls.clear()
fake_list["output"] = "codex-regcand-SPEC-907-1.service loaded active running reg\n"
td_r = d.teardown_attempt("SPEC-907-1", d.unit_name("SPEC-907", 1))
check("teardown_attempt: a surviving unit is reported and NOT verified (finding 3)",
      "codex-regcand-SPEC-907-1.service" in td_r["remaining_units"] and td_r["verified"] is False)
fake_list["output"] = ""

# ROUND-2 finding 1 — verifying INSIDE the outer unit's ExecStopPost sees that outer unit still
# 'deactivating'; it must be EXCLUDED (it is not a leaked slice member) or every hook falsely fails.
eu_aid = "SPEC-908-1"
eu_outer = d.unit_name("SPEC-908", 1)                 # codex-SPEC-908-1
calls.clear()
# Listing contains ONLY the deactivating outer unit + its (emptying) slice container.
fake_list["output"] = (f"{eu_outer}.service loaded deactivating stop outer\n"
                       f"{d.attempt_slice(eu_aid)} loaded active active slice\n")
td_eu = d.teardown_attempt(eu_aid, eu_outer, stop_outer=False)  # timeout-path shape
check("teardown_attempt: the deactivating OUTER unit is EXCLUDED from remaining (round-2 finding 1)",
      td_eu["remaining_units"] == [] and td_eu["verified"] is True)
# But a TRUE slice member still present alongside the deactivating outer unit is NOT excluded.
fake_list["output"] += f"codex-worker-{eu_aid}.service loaded active running worker\n"
td_eu2 = d.teardown_attempt(eu_aid, eu_outer, stop_outer=False)
check("teardown_attempt: a real slice member alongside the deactivating outer unit IS still caught",
      f"codex-worker-{eu_aid}.service" in td_eu2["remaining_units"] and td_eu2["verified"] is False)
fake_list["output"] = ""

# ROUND-3 finding 1 — the outer-unit exclusion is safe ONLY when the outer stop succeeded. If
# `systemctl --user stop <outer>` FAILS (stop_outer=True path), the outer unit may still be alive and
# able to spawn members, yet it is excluded from the remaining set — so verified MUST require
# outer_stop_rc == 0, or cancel/health would falsely read verified=True.
os_aid = "SPEC-910-1"
os_outer = d.unit_name("SPEC-910", 1)
calls.clear(); fake_outer_stop["rc"] = 1        # outer stop fails; listing is otherwise clean/empty
td_os = d.teardown_attempt(os_aid, os_outer)    # stop_outer=True (default)
check("teardown_attempt: a FAILED outer-unit stop is NOT verified despite the exclusion (round-3 finding 1)",
      td_os["outer_stop_rc"] == 1 and td_os["remaining_units"] == [] and td_os["query_ok"] is True
      and td_os["verified"] is False)
# The timeout path (stop_outer=False) does not stop the outer unit, so its rc never gates there.
td_os_to = d.teardown_attempt(os_aid, os_outer, stop_outer=False)
check("teardown_attempt: the timeout path (stop_outer=False) is unaffected by outer-stop rc",
      td_os_to["verified"] is True)
fake_outer_stop["rc"] = 0

# ==================================================================================================
# Group F — cmd_cancel(): stops the whole slice + the outer unit, verifies, exits per verification.
etmp = pathlib.Path(tempfile.mkdtemp())
d.STATE = etmp / "state"; d.STATE.mkdir()
eaid = "SPEC-902-1"
espec, en = d.parse_attempt_id(eaid)
eunit = d.unit_name(espec, en)
d.write_state(espec, {"attempt_id": eaid, "spec_id": espec, "attempt": en, "status": "running",
                      "unit": eunit})

calls.clear()
buf = io.StringIO()
try:
    with contextlib.redirect_stdout(buf):
        d.cmd_cancel(eaid)
    cancel_rc = 0
except SystemExit as e:
    cancel_rc = e.code
out = json.loads(buf.getvalue())
check("cmd_cancel: stops the attempt SLICE (not just worker+test unit names)",
      any(is_sudo_stop(c, d.attempt_slice(eaid)) for c in calls))
check("cmd_cancel: also stops the outer --user pipeline unit",
      any(is_user_stop(c, eunit) for c in calls))
check("cmd_cancel: producer stopped before the slice", cancel_rc == 0
      and first_idx(lambda c: is_user_stop(c, eunit)) < first_idx(lambda c: is_sudo_stop(c, d.attempt_slice(eaid))))
check("cmd_cancel: verified clean (fake systemctl reports empty) and exits 0",
      out["verified"] is True and out["remaining_units"] == [] and cancel_rc == 0)
est = d.read_state(espec)
check("cmd_cancel: state moves to interrupted/cancelled",
      est["status"] == "interrupted" and est["error_class"] == "cancelled")
check("cmd_cancel: an operator cancel is NOT relabeled a timeout", "timeout" not in est.get("detail", ""))

# cmd_cancel fail-closed: a failed verification query escalates + exits nonzero.
d.write_state(espec, {"attempt_id": eaid, "spec_id": espec, "attempt": en, "status": "running",
                      "unit": eunit})
esc_before = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
calls.clear(); fake_list["rc"] = 1
try:
    with contextlib.redirect_stdout(io.StringIO()):
        d.cmd_cancel(eaid)
    cancel_rc2 = 0
except SystemExit as e:
    cancel_rc2 = e.code
fake_list["rc"] = 0
esc_after = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
check("cmd_cancel: unverifiable teardown exits nonzero (fail closed, finding 3)", cancel_rc2 == 1)
check("cmd_cancel: unverifiable teardown escalates rather than warn-and-continue", esc_after > esc_before)

# ROUND-3 finding 1 — a FAILED outer-unit stop during cancel (listing otherwise clean) must exit
# nonzero + escalate, not falsely verify on the strength of the outer-unit exclusion alone. Uses a
# DISTINCT spec so its escalation file cannot collide with the query-fail case above (escalate names
# files spec_id + a second-resolution timestamp).
os2_aid = "SPEC-911-1"
os2_spec, os2_n = d.parse_attempt_id(os2_aid)
os2_unit = d.unit_name(os2_spec, os2_n)
d.write_state(os2_spec, {"attempt_id": os2_aid, "spec_id": os2_spec, "attempt": os2_n,
                         "status": "running", "unit": os2_unit})
esc_before_os = {p.name for p in d.ESCALATIONS.glob("*.json")} if d.ESCALATIONS.exists() else set()
calls.clear(); fake_outer_stop["rc"] = 1
try:
    with contextlib.redirect_stdout(io.StringIO()):
        d.cmd_cancel(os2_aid)
    cancel_rc3 = 0
except SystemExit as e:
    cancel_rc3 = e.code
fake_outer_stop["rc"] = 0
esc_new_os = ({p.name for p in d.ESCALATIONS.glob("*.json")} - esc_before_os) if d.ESCALATIONS.exists() else set()
check("cmd_cancel: a FAILED outer-unit stop exits nonzero + escalates (round-3 finding 1)",
      cancel_rc3 == 1 and any(n.startswith(os2_spec) for n in esc_new_os))

# ==================================================================================================
# Group G — cmd_timeout(): finding 4. The outer unit carries ExecStopPost=`timeout`, so a fired
# RuntimeMaxSec tears down + verifies the slice at stop time. Proves: (a) wiring is present, (b) a
# LIVE attempt is relabeled timeout + slice torn down + verified, (c) it does NOT try to stop the
# outer unit (systemd is already stopping the producer), (d) it is a no-op on an already-terminal
# state (does not clobber a normal finish or an operator cancel).
launch_src = inspect.getsource(d.cmd_launch)
check("cmd_launch wires ExecStopPost=`timeout` so RuntimeMaxSec fires teardown at stop time (finding 4)",
      "ExecStopPost" in launch_src and "timeout" in launch_src)
# ROUND-2 finding 3 — the outer unit's RuntimeMaxSec is tied to the REMAINING time to the absolute
# deadline (systemd hard-caps the whole attempt at deadline_ts), not a fresh full ceiling.
check("cmd_launch ties the outer unit RuntimeMaxSec to remaining-to-deadline (round-2 finding 3)",
      "outer_ceiling_s = remaining_ceiling_s(deadline_ts)" in launch_src
      and "RuntimeMaxSec={outer_ceiling_s}" in launch_src)
# ROUND-2 finding 3 — review()/spec-test/worker unisolated fallbacks cap the phase itself with a
# deadline `timeout` wrapper, not merely a pre-start check.
review_src = inspect.getsource(d.review)
check("review() caps the reviewer LLM call with a deadline `timeout` wrapper (round-2 finding 3)",
      "deadline_timeout_prefix" in review_src)
# R73 Job 3 split the pipeline: the worker phase lives in _run_pipeline, the spec-test phase in
# the shared _grade_phase — the asserted property (each unisolated phase wrapped, not pre-checked)
# is unchanged and now counted across both halves.
pipeline_src = inspect.getsource(d._run_pipeline) + inspect.getsource(d._grade_phase)
check("unisolated worker + spec-test phases use a deadline `timeout` wrapper, not just a pre-start check",
      pipeline_src.count("deadline_timeout_prefix") >= 2)
reg_src = inspect.getsource(d.run_regression_gate)
check("unisolated regression run is wrapped in a deadline `timeout` (round-2 finding 3)",
      '"timeout", "-k"' in reg_src)

gtmp = pathlib.Path(tempfile.mkdtemp())
d.STATE = gtmp / "state"; d.STATE.mkdir()
gaid = "SPEC-903-1"
gspec, gn = d.parse_attempt_id(gaid)
gunit = d.unit_name(gspec, gn)
d.write_state(gspec, {"attempt_id": gaid, "spec_id": gspec, "attempt": gn, "status": "running",
                      "unit": gunit})
calls.clear()
gbuf = io.StringIO()
try:
    with contextlib.redirect_stdout(gbuf):
        d.cmd_timeout(gaid)
    timeout_rc = 0
except SystemExit as e:
    timeout_rc = e.code
gout = json.loads(gbuf.getvalue())
check("cmd_timeout: tears down the attempt slice", any(is_sudo_stop(c, d.attempt_slice(gaid)) for c in calls))
check("cmd_timeout: does NOT stop the outer unit (systemd is already stopping the producer)",
      not any(is_user_stop(c, gunit) for c in calls))
check("cmd_timeout: verifies + exits 0 when clean", gout["verified"] is True and timeout_rc == 0)
gst = d.read_state(gspec)
check("cmd_timeout: a LIVE attempt is relabeled to timeout",
      gst["status"] == "interrupted" and gst["error_class"] == d.ERR_TIMEOUT)

# Already-terminal: cmd_timeout is teardown-only, never clobbers the recorded outcome.
d.write_state(gspec, {"attempt_id": gaid, "spec_id": gspec, "attempt": gn,
                      "status": "passed_pr_opened", "unit": gunit})
calls.clear()
try:
    with contextlib.redirect_stdout(io.StringIO()):
        d.cmd_timeout(gaid)
except SystemExit:
    pass
check("cmd_timeout: does NOT clobber an already-terminal state (idempotent, state-safe)",
      d.read_state(gspec)["status"] == "passed_pr_opened")
check("cmd_timeout: still tears the slice down even when state is already terminal",
      any(is_sudo_stop(c, d.attempt_slice(gaid)) for c in calls))

# ROUND-2 finding 2 — a verification failure during cleanup of an ALREADY-TERMINAL attempt (normal
# finish / cancel) must STILL escalate + exit nonzero, not only when the state was LIVE.
d.write_state(gspec, {"attempt_id": gaid, "spec_id": gspec, "attempt": gn,
                      "status": "passed_pr_opened", "unit": gunit})
g_esc_before = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
calls.clear(); fake_list["output"] = f"codex-worker-{gaid}.service loaded active running w\n"
try:
    with contextlib.redirect_stdout(io.StringIO()):
        d.cmd_timeout(gaid)
    g_timeout_rc = 0
except SystemExit as e:
    g_timeout_rc = e.code
fake_list["output"] = ""
g_esc_after = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
check("cmd_timeout: a leaked member during terminal-state cleanup escalates even when NOT LIVE (finding 2)",
      g_esc_after > g_esc_before and g_timeout_rc == 1)

# ==================================================================================================
# Group H — cmd_reconcile(): an outer unit found dead while state was LIVE (crash, box restart, or
# the outer unit's own RuntimeMaxSec) runs the SAME teardown, not just a relabel-and-walk-away.
ftmp = pathlib.Path(tempfile.mkdtemp())
d.STATE = ftmp / "state"; d.STATE.mkdir()
faid = "SPEC-904-1"
fspec, fn = d.parse_attempt_id(faid)
funit = d.unit_name(fspec, fn)
d.write_state(fspec, {"attempt_id": faid, "spec_id": fspec, "attempt": fn, "status": "running",
                      "unit": funit})
calls.clear()
fbuf = io.StringIO()
try:
    with contextlib.redirect_stdout(fbuf):
        d.cmd_reconcile()  # fake systemctl show returns nothing -> unit reads inactive -> "gone"
    recon_rc = 0
except SystemExit as e:
    recon_rc = e.code
recon = json.loads(fbuf.getvalue())
check("cmd_reconcile: an outer unit found dead while LIVE tears down the attempt slice",
      any(is_sudo_stop(c, d.attempt_slice(faid)) for c in calls))
check("cmd_reconcile: reports per-attempt teardown verification",
      recon["reconciled"] and recon["reconciled"][0].get("teardown_verified") is True)
check("cmd_reconcile: reports whether the live-units query itself succeeded (fail closed)",
      recon.get("live_units_query_ok") is True)
check("cmd_reconcile: a clean reconcile exits 0", recon_rc == 0)
fst = d.read_state(fspec)
check("cmd_reconcile: state moves to interrupted", fst["status"] == "interrupted")

# ROUND-2 finding 2 — a reconcile whose teardown leaves a member (or whose query fails) must exit
# nonzero + escalate, not print-and-return-zero.
d.write_state(fspec, {"attempt_id": faid, "spec_id": fspec, "attempt": fn, "status": "running",
                      "unit": funit})
r_esc_before = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
calls.clear(); fake_list["output"] = f"codex-regbase-{faid}.service loaded active running r\n"
try:
    with contextlib.redirect_stdout(io.StringIO()):
        d.cmd_reconcile()
    recon_rc2 = 0
except SystemExit as e:
    recon_rc2 = e.code
fake_list["output"] = ""
r_esc_after = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
check("cmd_reconcile: an unverifiable teardown exits nonzero + escalates (finding 2)",
      recon_rc2 == 1 and r_esc_after > r_esc_before)

# ROUND-3 finding 4 — a failed FINAL live-units query (no LIVE attempts to iterate) must ALSO write a
# durable escalation, matching every other fail-closed path, not just exit nonzero silently.
rtmp2 = pathlib.Path(tempfile.mkdtemp())
d.STATE = rtmp2 / "state"; d.STATE.mkdir()          # no LIVE attempts → loop is a no-op
before_recon_esc = {p.name for p in d.ESCALATIONS.glob("*.json")} if d.ESCALATIONS.exists() else set()
fake_list["rc"] = 1
try:
    with contextlib.redirect_stdout(io.StringIO()):
        d.cmd_reconcile()
    recon_rc3 = 0
except SystemExit as e:
    recon_rc3 = e.code
fake_list["rc"] = 0
new_recon_esc = ({p.name for p in d.ESCALATIONS.glob("*.json")} - before_recon_esc) if d.ESCALATIONS.exists() else set()
check("cmd_reconcile: a failed final live-units query exits nonzero AND writes an escalation (round-3 finding 4)",
      recon_rc3 == 1 and any(n.startswith("reconcile-") for n in new_recon_esc))

# ==================================================================================================
# Group I — cmd_health(): a confirmed-hang teardown that cannot be verified clean must exit nonzero
# + escalate (round-2 finding 2), so a health loop never reads a leaky kill as success. Drive two
# consecutive "dead" checks to reach confirmed_hang, with the fake showing the unit active + idle.
htmp = pathlib.Path(tempfile.mkdtemp())
d.STATE = htmp / "state"; d.STATE.mkdir()
d.ATTEMPTS = htmp / "attempts"
haid = "SPEC-909-1"
hspec, hn = d.parse_attempt_id(haid)
hunit = d.unit_name(hspec, hn)
(d.ATTEMPTS / hspec / str(hn) / "raw").mkdir(parents=True)
d.write_state(hspec, {"attempt_id": haid, "spec_id": hspec, "attempt": hn, "status": "running",
                      "unit": hunit})
# systemctl show → active + no CPU; no events file → idle_s huge → alert; two checks → confirmed_hang.
_orig_systemctl_show, _orig_journal = d.systemctl_show, d._journal_lines_since
d.systemctl_show = lambda unit, *props: {"ActiveState": "active", "SubState": "running",
                                         "CPUUsageNSec": "0"}
d._journal_lines_since = lambda unit, since_ts: 0
h_esc_before = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
calls.clear(); fake_list["output"] = f"codex-test-{haid}.service loaded active running t\n"
def run_health():
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            d.cmd_health(haid, inactivity_min=0)
        return 0
    except SystemExit as e:
        return e.code
run_health()                 # first dead check → alert_pending_confirm (no teardown yet)
health_rc = run_health()     # second dead check → confirmed_hang → teardown (leaky) → fail closed
fake_list["output"] = ""
d.systemctl_show, d._journal_lines_since = _orig_systemctl_show, _orig_journal
h_esc_after = len(list(d.ESCALATIONS.glob("*.json"))) if d.ESCALATIONS.exists() else 0
check("cmd_health: confirmed-hang stops the attempt slice",
      any(is_sudo_stop(c, d.attempt_slice(haid)) for c in calls))
check("cmd_health: an unverifiable confirmed-hang teardown exits nonzero + escalates (finding 2)",
      health_rc == 1 and h_esc_after > h_esc_before)

print()
print(f"{'FAIL' if fails else 'PASS'}: dispatch_cancel_teardown.sh ({len(fails)} failed)")
import sys as _sys
_sys.exit(1 if fails else 0)
PY
