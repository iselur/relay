#!/usr/bin/env python3
"""
scripts/dispatch.py — the Gate 2 dispatcher.

One deterministic tool that encodes the Gate 1 procedure. Subcommands:

    dispatch launch <spec-id>     validate, claim, start the unit; print attempt-id; return now
    dispatch status <attempt-id>  non-blocking state from .orchestrator/ + systemctl --user
    dispatch await  <attempt-id>  bounded-sleep polling; exit with the attempt's result code
    dispatch cancel <attempt-id>  stop the attempt's systemd unit (never a recorded PID)

Invariants (SETUP-BRIEF.md):
  - Every worker runs as a `systemd-run --user` transient unit in its own cgroup (Gate 2).
  - Validation first: schema-valid spec; approval digest matches; depends_on done; HALT absent;
    needs_network hard-refused (residual risk 13-B).
  - Orchestrator commits the worktree state (decision G1-A/C): the worker never touches git.
  - Immutable evidence: new attempt = new dir, never overwrite. Atomic state via tmp+rename+flock.
  - Structured error classes. MAX_PARALLEL=1. No auto-remediation (a failure stops and reports).
  - Even a launch that crashes at startup leaves a durable record.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

# ------------------------------------------------------------------ paths ----
ROOT = Path(__file__).resolve().parent.parent
SPECS = ROOT / "specs"
ORCH = ROOT / ".orchestrator"
APPROVALS = ORCH / "approvals"
ATTEMPTS = ORCH / "attempts"
STATE = ORCH / "state"
WORKTREES = ROOT / ".worktrees"
HALT = ORCH / "HALT"
SPEC_SCHEMA = SPECS / "spec.schema.json"
VERDICT_SCHEMA = ROOT / "scripts" / "verdict.schema.json"
VENV_PY = ROOT / ".venv" / "bin" / "python"

MAX_PARALLEL = 1
DEFAULT_CEILING_HOURS = 2.0

# Terminal vs live attempt statuses.
TERMINAL = {
    "passed_pr_opened", "failed_worker_error", "failed_integrity",
    "failed_scope", "failed_test", "failed_review", "interrupted", "error_launch",
    "spec_blocked",
}
LIVE = {"launching", "running"}

# Structured error classes (Appendix A#7 / Gate 2 requirement).
ERR_AUTH = "auth"
ERR_QUOTA = "quota_rate_limit"
ERR_SANDBOX = "sandbox_denial"
ERR_TIMEOUT = "timeout"
ERR_INTEGRITY = "integrity"
ERR_TEST = "test"
ERR_SCOPE = "scope"
ERR_REVIEW = "review"
ERR_WORKER = "worker_nonzero"
ERR_LAUNCH = "launch"
# policy-note item 2: worker signals the spec itself is unworkable; the old approval is void and a
# spec revision + new approval digest is required. Not a worker failure.
ERR_SPEC_BLOCKED = "spec_blocked"
ERR_NONE = None


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def die(msg: str, code: int = 2) -> "typing.NoReturn":  # noqa: F821
    sys.stderr.write(f"dispatch: {msg}\n")
    sys.exit(code)


def run(cmd, **kw):
    """Run a command, returning CompletedProcess. Never raises on nonzero."""
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    return subprocess.run(cmd, **kw)


def git(*args, cwd=ROOT, check=True):
    cp = run(["git", *args], cwd=str(cwd))
    if check and cp.returncode != 0:
        die(f"git {' '.join(args)} failed: {cp.stderr.strip()}")
    return cp.stdout.strip()


# --------------------------------------------------------------- atomic io ----
def atomic_write(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def write_state(spec_id: str, state: dict) -> None:
    """Atomic, flock-guarded state write. .orchestrator/state/<id>.json (gitignored)."""
    STATE.mkdir(parents=True, exist_ok=True)
    lock = STATE / ".lock"
    with open(lock, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = {**state, "updated": now()}
            atomic_write(STATE / f"{spec_id}.json", json.dumps(state, indent=2))
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def read_state(spec_id: str) -> dict | None:
    p = STATE / f"{spec_id}.json"
    if not p.exists():
        return None
    return json.loads(p.read_text())


def all_states() -> list[dict]:
    if not STATE.exists():
        return []
    out = []
    for p in STATE.glob("*.json"):
        try:
            out.append(json.loads(p.read_text()))
        except Exception:
            pass
    return out


# ----------------------------------------------------------- spec/approval ----
def spec_path(spec_id: str) -> Path:
    return SPECS / f"{spec_id}.yaml"


def spec_digest(spec_id: str) -> str:
    return hashlib.sha256(spec_path(spec_id).read_bytes()).hexdigest()


def load_spec(spec_id: str) -> dict:
    p = spec_path(spec_id)
    if not p.exists():
        die(f"spec not found: {p}")
    try:
        data = yaml.safe_load(p.read_text())
    except yaml.YAMLError as e:
        die(f"spec YAML parse error: {e}")
    if not isinstance(data, dict):
        die("spec is not a mapping")
    return data


def validate_spec(spec_id: str) -> tuple[dict, list[str]]:
    """Return (spec, errors). Errors empty => schema-valid."""
    spec = load_spec(spec_id)
    schema = json.loads(SPEC_SCHEMA.read_text())
    errors = [f"{'/'.join(map(str, e.path)) or '<root>'}: {e.message}"
              for e in Draft202012Validator(schema).iter_errors(spec)]
    if spec.get("id") != spec_id:
        errors.append(f"id field '{spec.get('id')}' != filename stem '{spec_id}'")
    return spec, errors


def approval_for(digest: str) -> dict | None:
    p = APPROVALS / f"{digest}.json"
    if not p.exists():
        return None
    return json.loads(p.read_text())


def preflight(spec_id: str) -> dict:
    """
    All the validation-first gates. Returns a context dict on success; dies with a
    structured message otherwise. This is refused-before-launch policy.
    """
    if HALT.exists():
        die(f"HALT present ({HALT}); all launches blocked. Remove it to resume.", 3)

    spec, errors = validate_spec(spec_id)
    if errors:
        die("spec schema-invalid:\n  - " + "\n  - ".join(errors), 4)

    # needs_network hard-refused (Val decision, residual risk 13-B).
    if spec.get("needs_network", False):
        die("needs_network:true is REFUSED on this host: the Codex sandbox cannot restrict "
            "reads (risk 13-B), so a networked worker could exfiltrate credentials. Requires "
            "the dedicated worker user/container (D5 endgame) first.", 5)

    digest = spec_digest(spec_id)
    approval = approval_for(digest)
    if approval is None:
        die(f"no approval artifact for digest {digest} (spec unapproved or edited since "
            f"approval). Expected {APPROVALS / (digest + '.json')}.", 6)
    if approval.get("spec_digest") != digest:
        die("approval artifact's spec_digest does not match the current spec file.", 6)

    # depends_on all done.
    for dep in spec.get("depends_on", []):
        st = read_state(dep)
        if not st or st.get("status") != "passed_pr_opened":
            die(f"dependency {dep} not satisfied (state="
                f"{st.get('status') if st else 'none'}).", 7)

    # MAX_PARALLEL: refuse if any live attempt exists.
    live = [s for s in all_states() if s.get("status") in LIVE]
    if len(live) >= MAX_PARALLEL:
        die(f"MAX_PARALLEL={MAX_PARALLEL} reached; live attempt(s): "
            f"{[s.get('attempt_id') for s in live]}.", 8)

    return {"spec": spec, "digest": digest, "approval": approval}


# ------------------------------------------------------------------ units ----
def unit_name(spec_id: str, n: int) -> str:
    return f"codex-{spec_id}-{n}"


def systemctl_show(unit: str, *props) -> dict:
    cp = run(["systemctl", "--user", "show", unit, *[f"-p{p}" for p in props]])
    out = {}
    for line in cp.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def unit_active(unit: str) -> bool:
    return systemctl_show(unit, "ActiveState").get("ActiveState") in {"active", "activating"}


# ------------------------------------------------------------- attempt ids ----
def next_attempt(spec_id: str) -> int:
    d = ATTEMPTS / spec_id
    if not d.exists():
        return 1
    ns = [int(p.name) for p in d.iterdir() if p.name.isdigit()]
    return (max(ns) + 1) if ns else 1


def parse_attempt_id(attempt_id: str) -> tuple[str, int]:
    m = re.match(r"^(SPEC-\d{3,})-(\d+)$", attempt_id)
    if not m:
        die(f"bad attempt-id '{attempt_id}' (expected e.g. SPEC-001-1)")
    return m.group(1), int(m.group(2))


# =============================================================== launch =======
def cmd_launch(spec_id: str) -> None:
    ctx = preflight(spec_id)
    spec, digest, approval = ctx["spec"], ctx["digest"], ctx["approval"]

    n = next_attempt(spec_id)
    attempt_id = f"{spec_id}-{n}"
    att_dir = ATTEMPTS / spec_id / str(n)
    (att_dir / "raw").mkdir(parents=True, exist_ok=True)

    # Durable record BEFORE anything can crash (July lesson: untraceable launches).
    base_sha = None
    write_state(spec_id, {
        "attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
        "spec_digest": digest, "status": "launching", "error_class": None,
        "unit": unit_name(spec_id, n), "created": now(),
    })

    try:
        git("fetch", "--quiet", "origin", approval.get("base_branch", "integration"))
        base_sha = git("rev-parse", f"origin/{approval.get('base_branch', 'integration')}")
        branch = f"codex/{attempt_id}"
        wt = WORKTREES / attempt_id
        if wt.exists():
            die(f"worktree {wt} already exists (attempt not unique?)", 9)
        git("worktree", "add", "--quiet", "-b", branch, str(wt), base_sha)
    except SystemExit:
        write_state(spec_id, {**read_state(spec_id), "status": "error_launch",
                              "error_class": ERR_LAUNCH,
                              "detail": "base/worktree setup failed"})
        raise

    ceiling_h = float(spec.get("hard_ceiling_hours", DEFAULT_CEILING_HOURS))
    ceiling_s = int(ceiling_h * 3600)

    # Persist the launch context the unit's _run needs.
    atomic_write(att_dir / "launch.json", json.dumps({
        "attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
        "spec_digest": digest, "base_sha": base_sha, "branch": branch,
        "worktree": str(wt), "worker_model": approval.get("worker_model", "gpt-5.6-sol"),
        "worker_effort": approval.get("worker_reasoning_effort", "high"),
        "reviewer_model": approval.get("reviewer_model", "claude-fable-5"),
        "reviewer_effort": approval.get("reviewer_effort", "high"),
        "test_command": spec["test_command"], "approved_scope": approval["approved_scope"],
        "hard_ceiling_hours": ceiling_h, "created": now(),
    }, indent=2))

    unit = unit_name(spec_id, n)
    cmd = [
        "systemd-run", "--user", f"--unit={unit}", "--collect",
        f"--property=Description=Codex worker {attempt_id}",
        f"--property=RuntimeMaxSec={ceiling_s}",   # hard ceiling (D10), default-on
        "--setenv=HOME=" + os.environ.get("HOME", "/home/val"),
        "--setenv=PATH=" + os.environ.get("PATH", "/usr/bin:/bin"),
        "--setenv=XDG_RUNTIME_DIR=" + os.environ.get("XDG_RUNTIME_DIR", ""),
        str(ROOT / "scripts" / "dispatch"), "_run", attempt_id,
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        write_state(spec_id, {**read_state(spec_id), "status": "error_launch",
                              "error_class": ERR_LAUNCH,
                              "detail": f"systemd-run failed: {cp.stderr.strip()}"})
        die(f"failed to start unit: {cp.stderr.strip()}", 10)

    write_state(spec_id, {**read_state(spec_id), "status": "running", "base_sha": base_sha})
    print(attempt_id)


# ================================================================ _run ========
def _run(attempt_id: str) -> None:
    """Runs INSIDE the systemd unit. The full attempt pipeline (Gate 1 steps 3-9)."""
    spec_id, n = parse_attempt_id(attempt_id)
    att = ATTEMPTS / spec_id / str(n)
    lc = json.loads((att / "launch.json").read_text())
    wt = Path(lc["worktree"])
    raw = att / "raw"

    def finish(status: str, err_class, **extra) -> None:
        result = {
            "attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
            "spec_digest": lc["spec_digest"], "base_sha": lc["base_sha"],
            "worker_model": lc["worker_model"], "reviewer_model": lc["reviewer_model"],
            "sandbox_mode": "workspace-write", "network": "off", "env_scrubbed": True,
            "test_command": lc["test_command"], "status": status,
            "error_class": err_class, "commit_policy": "orchestrator-commits (G1-A/C)",
            "finished": now(), **extra,
        }
        atomic_write(att / "result.json", json.dumps(result, indent=2))
        write_state(spec_id, {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                              "spec_digest": lc["spec_digest"], "status": status,
                              "error_class": err_class, "unit": unit_name(spec_id, n),
                              **{k: extra[k] for k in ("worker_commit", "pr_url") if k in extra}})
        sys.exit(0 if status == "passed_pr_opened" else 1)

    try:
        _run_pipeline(attempt_id, spec_id, n, att, lc, wt, raw, finish)
    except SystemExit:
        raise
    except Exception as e:  # any unexpected failure still leaves a terminal record
        import traceback
        (raw / "run-traceback.txt").write_text(traceback.format_exc())
        finish("failed_worker_error", ERR_WORKER, detail=f"dispatch _run crashed: {e}")


def _run_pipeline(attempt_id, spec_id, n, att, lc, wt, raw, finish) -> None:
    # --- step 3: run the worker (scrubbed env, network off) --------------------
    # Fixed preamble. Planning policy per policy-note item 2. Commit policy per G1-A/C.
    preamble = (
        "Implement this spec. Modify only in-scope paths. Run the test command until it exits 0. "
        "Leave your changes in the working tree; do NOT commit or push — the orchestrator commits "
        "your work.\n"
        "Inspect relevant code and tests before editing. For non-trivial tasks, maintain a "
        "concise, revisable implementation checklist covering intended files and verification; "
        "skip it for trivial tasks. The approved spec and evidence gates remain binding. If "
        "discovery invalidates the spec or approved scope (impossible acceptance criteria, wrong "
        "test command, inadequate scope), stop and report SPEC_BLOCKED on its own line followed by "
        "the reason — never improvise beyond the spec."
    )
    prompt = preamble + "\n\n=== SPEC ===\n" + spec_path(spec_id).read_text()
    (raw / "worker-prompt.txt").write_text(prompt)

    scrubbed = {
        "HOME": os.environ.get("HOME", "/home/val"), "USER": "val", "LOGNAME": "val",
        "PATH": "/home/val/.local/bin:/usr/bin:/bin", "CODEX_HOME": "/home/val/.codex",
        "TERM": "dumb", "LANG": "C.UTF-8",
    }
    worker_cmd = [
        "codex", "exec", "--cd", str(wt), "--sandbox", "workspace-write",
        "-m", lc["worker_model"], "-c", f"model_reasoning_effort={lc['worker_effort']}",
        "--json", "--output-last-message", str(raw / "worker-last-message.txt"), prompt,
    ]
    with open(raw / "events.jsonl", "w") as ev, open(raw / "worker-stderr.txt", "w") as er, \
            open(os.devnull) as devnull:
        wc = subprocess.run(worker_cmd, env=scrubbed, stdin=devnull, stdout=ev, stderr=er)

    stderr_txt = (raw / "worker-stderr.txt").read_text()
    last_message = ""
    if (raw / "worker-last-message.txt").exists():
        last_message = (raw / "worker-last-message.txt").read_text()

    # policy-note item 2: worker signalled the spec is unworkable. Old approval is void; a spec
    # revision + new approval digest is required. Terminal, but NOT a worker failure.
    if re.search(r"(^|\n)\s*SPEC_BLOCKED\b", last_message):
        finish("spec_blocked", ERR_SPEC_BLOCKED, worker_exit=wc.returncode,
               detail="worker reported SPEC_BLOCKED; spec revision + new approval required",
               worker_message=last_message.strip()[:2000])

    ec = classify_worker(wc.returncode, stderr_txt, raw / "events.jsonl")
    if ec is not None:
        # policy-note item 1: a quota/rate-limit mid-attempt is INTERRUPTED (external capacity),
        # not a merit failure. Preserve evidence, stop; resume ONLY as a fresh attempt when
        # capacity returns. The dispatcher never resumes a partial worktree.
        if ec == ERR_QUOTA:
            finish("interrupted", ERR_QUOTA, worker_exit=wc.returncode,
                   detail="Codex quota/rate-limit hit mid-attempt; re-launch as a fresh attempt "
                          "after capacity returns. Never hand-finish this worktree.")
        finish("failed_worker_error", ec, worker_exit=wc.returncode,
               detail=f"worker error class={ec}")

    # --- decision G1-A/C: ORCHESTRATOR commits the worktree state --------------
    changed = git("status", "--porcelain=v2", "--untracked-files=all", cwd=wt)
    if not changed.strip():
        finish("failed_worker_error", ERR_WORKER, worker_exit=wc.returncode,
               detail="worker produced no changes")
    git("add", "-A", cwd=wt)
    env = os.environ.copy()
    env["GIT_AUTHOR_NAME"] = f"Codex {lc['worker_model']}"
    env["GIT_AUTHOR_EMAIL"] = "codex-worker@orchestrator.local"
    msg = (f"{spec_id}: worker output (attempt {n})\n\n"
           f"Codex {lc['worker_model']} (reasoning={lc['worker_effort']}), packaged by the "
           f"orchestrator (G1-A/C).\n\nspec_digest: {lc['spec_digest']}\n"
           f"base_sha: {lc['base_sha']}\nattempt: {n}")
    cp = run(["git", "commit", "-q", "-m", msg], cwd=str(wt), env=env)
    if cp.returncode != 0:
        finish("failed_worker_error", ERR_WORKER, detail=f"commit failed: {cp.stderr.strip()}")
    worker_commit = git("rev-parse", "HEAD", cwd=wt)

    # --- step 5: integrity preconditions --------------------------------------
    integ, ok = integrity(wt, lc["base_sha"], worker_commit)
    atomic_write(att / "integrity.json", json.dumps(integ, indent=2))
    if not ok:
        finish("failed_integrity", ERR_INTEGRITY, worker_commit=worker_commit, integrity=integ)

    # --- step 6: scope check (NUL-safe) ---------------------------------------
    scope = scope_check(wt, lc["base_sha"], worker_commit, lc["approved_scope"])
    atomic_write(att / "scope.json", json.dumps(scope, indent=2))
    if scope["result"] != "PASS":
        finish("failed_scope", ERR_SCOPE, worker_commit=worker_commit, scope=scope)

    # --- step 7: test ----------------------------------------------------------
    tc = run(["bash", "-c", lc["test_command"]], cwd=str(wt))
    (att / "test.log").write_text((tc.stdout or "") + (tc.stderr or ""))
    if tc.returncode != 0:
        finish("failed_test", ERR_TEST, worker_commit=worker_commit, test_exit=tc.returncode)

    # --- step 8: reviewer (bound, fail-closed) --------------------------------
    verdict, vraw = review(att, spec_id, lc, worker_commit)
    atomic_write(att / "review.json", json.dumps(verdict, indent=2) if verdict else "{}")
    if not verdict or verdict.get("verdict") != "PASS":
        finish("failed_review", ERR_REVIEW, worker_commit=worker_commit,
               review_verdict=(verdict or {}).get("verdict", "malformed"))

    # --- step 9: push + draft PR (orchestrator only) --------------------------
    if git("rev-parse", "HEAD", cwd=wt) != worker_commit:
        finish("failed_integrity", ERR_INTEGRITY, worker_commit=worker_commit,
               detail="head moved after review")
    git("push", "-u", "origin", lc["branch"], cwd=wt)
    pr = run(["gh", "pr", "create", "--draft", "--base",
              "integration", "--head", lc["branch"],
              "--title", f"{spec_id}: {load_spec(spec_id).get('title', '')}",
              "--body", pr_body(spec_id, lc, worker_commit)], cwd=str(ROOT))
    pr_url = (pr.stdout or "").strip().splitlines()[-1] if pr.returncode == 0 else None
    if pr.returncode != 0:
        finish("failed_worker_error", ERR_WORKER, worker_commit=worker_commit,
               detail=f"pr create failed: {pr.stderr.strip()}")

    hashes = raw_hashes(raw)
    atomic_write(att / "raw-sha256.txt", hashes)
    finish("passed_pr_opened", ERR_NONE, worker_commit=worker_commit, pr_url=pr_url)


# ----------------------------------------------------------- worker helpers ----
def classify_worker(exit_code: int, stderr: str, events_path: Path):
    """Return a structured error class, or None if the worker ran to completion."""
    low = stderr.lower()
    if "429" in stderr or "too many requests" in low or "rate limit" in low:
        return ERR_QUOTA
    if "not logged in" in low or "401" in stderr or "403" in stderr or "unauthorized" in low:
        return ERR_AUTH
    # A worker killed by RuntimeMaxSec: unit terminated; codex exit is nonzero/none.
    saw_turn_complete = False
    try:
        for line in events_path.read_text().splitlines():
            if '"type":"turn.completed"' in line or '"turn.completed"' in line:
                saw_turn_complete = True
    except Exception:
        pass
    if not saw_turn_complete and exit_code != 0:
        # Sandbox failures surface in the final message / stderr.
        if "sandbox" in low or "operation not permitted" in low or "bwrap" in low:
            return ERR_SANDBOX
        return ERR_WORKER
    return None


def integrity(wt: Path, base: str, wc: str) -> tuple[dict, bool]:
    head = git("rev-parse", "HEAD", cwd=wt)
    desc = run(["git", "merge-base", "--is-ancestor", base, wc], cwd=str(wt)).returncode == 0
    merges = git("rev-list", "--merges", f"{base}..{wc}", cwd=wt)
    n_merges = len([m for m in merges.splitlines() if m.strip()])
    porcelain = git("status", "--porcelain=v2", "-z", "--untracked-files=all", cwd=wt)
    clean = porcelain.strip("\x00").strip() == ""
    res = {
        "base_sha": base, "worker_commit": wc,
        "head_equals_worker_commit": head == wc,
        "descends_from_base": desc, "merge_commits": n_merges, "worktree_clean": clean,
    }
    ok = res["head_equals_worker_commit"] and desc and n_merges == 0 and clean
    res["result"] = "PASS" if ok else "FAIL"
    return res, ok


def _match_glob(path: str, globs: list[str]) -> bool:
    from fnmatch import fnmatch
    for g in globs:
        if g.endswith("/**"):
            if path == g[:-3] or path.startswith(g[:-3] + "/"):
                return True
        elif fnmatch(path, g):
            return True
    return False


def scope_check(wt: Path, base: str, wc: str, globs: list[str]) -> dict:
    cp = run(["git", "diff", "--name-status", "-z", f"{base}..{wc}"], cwd=str(wt))
    toks = cp.stdout.split("\x00")
    changed, oos = [], []
    i = 0
    while i < len(toks):
        status = toks[i]
        if not status:
            i += 1
            continue
        if status.startswith("R"):          # rename: source + dest
            src, dst = toks[i + 1], toks[i + 2]
            i += 3
            for p in (src, dst):
                changed.append(p)
                if not _match_glob(p, globs):
                    oos.append(p)
        else:
            p = toks[i + 1]
            i += 2
            changed.append(p)
            if not _match_glob(p, globs):
                oos.append(p)
    return {"approved_scope": globs, "changed": changed, "out_of_scope": oos,
            "result": "PASS" if not oos else "FAIL"}


def review(att: Path, spec_id: str, lc: dict, wc: str):
    # policy-note item 2: mandatory structured rubric. The worker's plan/checklist is NEVER
    # included here (confirmation-bias contamination) — only spec, diff, and orchestrator evidence.
    wt = Path(lc["worktree"])
    diff = git("diff", f"{lc['base_sha']}..{wc}", cwd=wt)
    req = (
        "You are a code reviewer acting as a hard, fail-closed gate. Review ONE worker change "
        "against ONE spec. Return a verdict only; do not fix anything. There is NO planning "
        "phase.\n\n"
        "Fill the structured rubric: `criteria[]` — one entry per acceptance criterion (in order) "
        "with result MET/UNMET and a concrete evidence reference (path/line/diff/test excerpt); "
        "`scope_finding`; `regression_finding`; `security_findings` (injected secrets, unsafe "
        "shell, credential access, network use). PASS only if EVERY criterion is MET and no "
        "blocking scope/regression/security finding exists; otherwise FAIL. If evidence is "
        "missing or ambiguous, FAIL (fail closed). `reasons[]` must be non-empty. You MUST echo "
        "spec_digest, base_sha and worker_commit verbatim; the verdict is void otherwise. "
        "schema_version is \"2\".\n\n=== SPEC ===\n" + spec_path(spec_id).read_text() +
        f"\n\n=== BINDING ===\nspec_digest: {lc['spec_digest']}\nbase_sha: {lc['base_sha']}\n"
        f"worker_commit: {wc}\n\n=== EVIDENCE (from the orchestrator, not the worker) ===\n"
        f"integrity: PASS\nscope: PASS\ntest_command: {lc['test_command']} exited 0\n\n"
        "=== DIFF ===\n" + diff
    )
    (att / "raw" / "review-request.txt").write_text(req)
    schema_obj = json.loads(VERDICT_SCHEMA.read_text())
    cmd = [
        "claude", "-p", "--output-format", "json", "--json-schema", json.dumps(schema_obj),
        "--model", lc["reviewer_model"].replace("claude-fable-5", "fable"),
        "--effort", lc["reviewer_effort"],
        "--allowedTools", "Read", "Grep", "Glob",
        "--disallowedTools", "Bash", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch",
        "Task", "--permission-mode", "manual",
    ]
    cp = run(cmd, input=req)
    (att / "raw" / "review-envelope.json").write_text(cp.stdout or "")
    try:
        verdict = json.loads(json.loads(cp.stdout)["result"])
    except Exception:
        return None, cp.stdout
    # Fail-closed validation: structural schema, binding, and PASS/MET consistency.
    try:
        Draft202012Validator(schema_obj).validate(verdict)
    except Exception:
        return None, cp.stdout
    if (verdict.get("spec_digest") != lc["spec_digest"]
            or verdict.get("base_sha") != lc["base_sha"]
            or verdict.get("worker_commit") != wc
            or verdict.get("schema_version") != "2"):
        return None, cp.stdout
    # A PASS is invalid if any criterion is UNMET (policy-note item 2).
    if verdict.get("verdict") == "PASS" and any(
            c.get("result") != "MET" for c in verdict.get("criteria", [])):
        return None, cp.stdout
    return verdict, cp.stdout


def raw_hashes(raw: Path) -> str:
    lines = []
    for p in sorted(raw.iterdir()):
        if p.is_file():
            lines.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}")
    return "\n".join(lines) + "\n"


def pr_body(spec_id: str, lc: dict, wc: str) -> str:
    return (
        f"Dispatched attempt **{lc['attempt_id']}** (Gate 2).\n\n"
        f"| field | value |\n|---|---|\n"
        f"| spec_digest | `{lc['spec_digest']}` |\n"
        f"| base_sha | `{lc['base_sha']}` |\n"
        f"| worker_commit | `{wc}` |\n"
        f"| worker | `{lc['worker_model']}` (reasoning={lc['worker_effort']}), sandbox=workspace-write, network=off |\n"
        f"| reviewer | `{lc['reviewer_model']}` → PASS (bound) |\n\n"
        f"Integrity/scope/test/review all PASS. Provenance under "
        f"`.orchestrator/attempts/{spec_id}/{lc['attempt']}/`. Draft: CI + branch protection are "
        f"the hard gate; Val merges (D9/D12). Commit authored by the worker, packaged by the "
        f"orchestrator (G1-A/C)."
    )


# =============================================================== status =======
def cmd_status(attempt_id: str) -> None:
    spec_id, n = parse_attempt_id(attempt_id)
    st = read_state(spec_id) or {}
    unit = unit_name(spec_id, n)
    show = systemctl_show(unit, "ActiveState", "SubState", "Result", "ExecMainStatus")
    result_file = ATTEMPTS / spec_id / str(n) / "result.json"
    result = json.loads(result_file.read_text()) if result_file.exists() else None
    out = {
        "attempt_id": attempt_id,
        "state_status": st.get("status") if st.get("attempt_id") == attempt_id else "unknown",
        "error_class": st.get("error_class"),
        "unit": unit,
        "unit_active_state": show.get("ActiveState", "gone"),
        "unit_result": show.get("Result"),
        "result": result,
    }
    print(json.dumps(out, indent=2))


# ================================================================ await =======
def cmd_await(attempt_id: str, interval: int = 5, max_wait: int = 8 * 3600) -> None:
    spec_id, n = parse_attempt_id(attempt_id)
    unit = unit_name(spec_id, n)
    waited = 0
    while waited < max_wait:
        st = read_state(spec_id) or {}
        status = st.get("status") if st.get("attempt_id") == attempt_id else None
        if status in TERMINAL:
            print(json.dumps({"attempt_id": attempt_id, "status": status,
                              "error_class": st.get("error_class")}))
            sys.exit(0 if status == "passed_pr_opened" else 1)
        # Unit gone but state not terminal => crash/interrupted.
        if status in LIVE and not unit_active(unit):
            time.sleep(2)  # settle: _run may be writing terminal state
            st = read_state(spec_id) or {}
            if st.get("status") in LIVE:
                write_state(spec_id, {**st, "status": "interrupted",
                                      "error_class": ERR_WORKER,
                                      "detail": "unit exited without terminal state"})
                print(json.dumps({"attempt_id": attempt_id, "status": "interrupted"}))
                sys.exit(1)
        time.sleep(interval)
        waited += interval
    die(f"await timed out after {max_wait}s", 11)


# =============================================================== cancel =======
def cmd_cancel(attempt_id: str) -> None:
    spec_id, n = parse_attempt_id(attempt_id)
    unit = unit_name(spec_id, n)
    cp = run(["systemctl", "--user", "stop", unit])
    st = read_state(spec_id) or {}
    if st.get("attempt_id") == attempt_id and st.get("status") in LIVE:
        write_state(spec_id, {**st, "status": "interrupted", "error_class": "cancelled",
                              "detail": "cancelled by operator"})
    print(json.dumps({"attempt_id": attempt_id, "unit": unit,
                      "stop_rc": cp.returncode, "stderr": cp.stderr.strip()}))


# ================================================================= main =======
def main() -> None:
    ap = argparse.ArgumentParser(prog="dispatch")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("launch",):
        p = sub.add_parser(name)
        p.add_argument("spec_id")
    for name in ("status", "await", "cancel", "_run"):
        p = sub.add_parser(name)
        p.add_argument("attempt_id")
    args = ap.parse_args()

    if args.cmd == "launch":
        cmd_launch(args.spec_id)
    elif args.cmd == "status":
        cmd_status(args.attempt_id)
    elif args.cmd == "await":
        cmd_await(args.attempt_id)
    elif args.cmd == "cancel":
        cmd_cancel(args.attempt_id)
    elif args.cmd == "_run":
        _run(args.attempt_id)


if __name__ == "__main__":
    main()
