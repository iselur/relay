#!/usr/bin/env python3
"""
scripts/dispatch.py — the Gate 2 dispatcher.

One deterministic tool that encodes the Gate 1 procedure. Subcommands:

    dispatch launch <spec-id>     validate, claim, start the unit; print attempt-id; return now
    dispatch status <attempt-id>  non-blocking state from .orchestrator/ + systemctl --user
    dispatch await  <attempt-id>  bounded-sleep polling; exit with the attempt's result code
    dispatch cancel <attempt-id>  stop the attempt's systemd unit (never a recorded PID)

Invariants (CLAUDE.md):
  - Every worker runs as a `systemd-run --user` transient unit in its own cgroup (Gate 2).
  - Validation first: schema-valid spec; approval digest matches; depends_on done; HALT absent;
    needs_network hard-refused (residual risk 13-B).
  - Orchestrator commits the worktree state (decision G1-A/C): the worker never touches git.
  - Immutable evidence: new attempt = new dir, never overwrite. Atomic state via tmp+rename+flock.
  - Structured error classes. MAX_PARALLEL=3 (Gate 3 part 3): unique branch/worktree per attempt,
    atomic slot claim; a base that moved while an attempt ran (a sibling integrated) is refused at
    push (stale_base) and re-run by the orchestrator as a fresh attempt. No auto-remediation.
  - Even a launch that crashes at startup leaves a durable record.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shutil
import stat as stat_module
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
# R71: the machine source of truth for role→model mapping (rev-4 taxonomy). Loaded ONCE per
# launch by load_model_config() and frozen into launch.json (lc), so a mid-run edit never
# changes a running attempt. Any read or validation error refuses the launch — there is no
# silent hard-coded fallback.
MODEL_CONFIG = ROOT / "scripts" / "models.json"
# Pre-R71 launch records carry none of the frozen config fields. An attempt in flight across the
# upgrade keeps the behavior it was launched under (round-2 review, finding 2): the shipped
# Fable CLI alias. This constant describes those historical records — it is compatibility, not a
# fallback for config errors, and no NEW launch ever reads it (cmd_launch always freezes the
# config's values). R94 removed the R69 reviewer failover pair (owner closed R69: a retired
# reviewer model is handled by a manual models.json flip, not automation).
LEGACY_LAUNCH_DEFAULTS = {
    "cli_aliases": {"claude-fable-5": "fable"},
}
# R73 Job 1: launch records that predate vendor freezing were all codex-worker/claude-reviewer.
# A SEPARATE all-or-none group from LEGACY_LAUNCH_DEFAULTS: records from the config era but
# before vendor freezing legally carry 3 model keys + 0 vendor keys, which must read as legacy
# here — never as corrupt (owner-extension precedent: partial sets refuse, disjoint eras don't).
LEGACY_VENDOR_DEFAULTS = {"worker_vendor": "codex", "reviewer_vendor": "claude"}
KNOWN_VENDORS = ("claude", "codex", "kimi")   # closed world: matches scripts/models_check.py VENDORS


def _load_vendor_adapters():
    """Load scripts/vendor_adapters.py ONCE, at dispatcher import (R73 round-2 review, blocking:
    loading at review time read the LIVE checkout, so an attempt launched under dispatcher A
    could execute adapter B installed mid-attempt — an unreviewed mixed version exactly around
    argv construction and verdict extraction). The module is pinned when this process starts;
    a load failure pins None and review() fails closed without invoking any reviewer."""
    try:
        spec = importlib.util.spec_from_file_location(
            "vendor_adapters", ROOT / "scripts" / "vendor_adapters.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, None
    except Exception as exc:
        return None, f"{type(exc).__name__}: {exc}"


VENDOR_ADAPTERS, VENDOR_ADAPTERS_ERR = _load_vendor_adapters()


def lc_frozen_vendor_fields(lc: dict) -> "dict | None":
    """Both frozen vendor fields from a launch record, the pre-freezing defaults when NEITHER
    is present, and None — refuse, fail closed — when exactly one is (corrupt record) or when
    either value is not a known vendor (R73 round-1 review: presence alone let a corrupt
    worker_vendor ride along while routing happened on reviewer_vendor only; BOTH frozen
    values must be classifiable or the record is corrupt)."""
    present = [k for k in LEGACY_VENDOR_DEFAULTS if k in lc]
    if len(present) == len(LEGACY_VENDOR_DEFAULTS):
        fields = {k: lc[k] for k in LEGACY_VENDOR_DEFAULTS}
        if any(v not in KNOWN_VENDORS for v in fields.values()):
            return None
        return fields
    if not present:
        return dict(LEGACY_VENDOR_DEFAULTS)
    return None


def lc_frozen_model_fields(lc: dict) -> dict:
    """The frozen model fields from a launch record: the record's own when present, the shipped
    pre-config defaults for a genuine pre-R71 record (since R94 the group is the alias map
    alone, so present-or-legacy is exhaustive — no partial set exists to refuse)."""
    if all(k in lc for k in LEGACY_LAUNCH_DEFAULTS):
        return {k: lc[k] for k in LEGACY_LAUNCH_DEFAULTS}
    return dict(LEGACY_LAUNCH_DEFAULTS)
# Approval artifact shapes (B1). Approvals were trusted by digest+instance equality only, and the
# per-attempt high-risk approval by mere file EXISTENCE — an empty or garbage file authorized a
# high-risk dispatch. Both are now schema-validated AND bound to this spec/instance (and attempt).
# ISO-8601 instant with an explicit timezone (Z or ±HH:MM), e.g. 2026-07-13T11:20:00Z. A bare
# nonempty string is not a timestamp (B1 round-2): syntax is enforced, not just presence.
_TS_PATTERN = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$"
APPROVAL_SCHEMA = {
    "type": "object",
    "additionalProperties": False,     # unknown fields cannot smuggle anything past validation
    "required": ["spec_id", "spec_digest", "instance_id", "approver", "approved_scope",
                 "risk_class", "timestamp"],
    "properties": {
        "spec_id": {"type": "string", "minLength": 1},
        "spec_digest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "spec_digest_method": {"type": "string"},
        "instance_id": {"type": "string", "pattern": "^[0-9a-f]{32}$"},
        "approver": {"type": "string", "minLength": 1},
        "approved_scope": {"type": "array", "items": {"type": "string", "minLength": 1},
                           "minItems": 1},
        "risk_class": {"enum": ["low", "default", "high"]},
        "timestamp": {"type": "string", "pattern": _TS_PATTERN},
        "base_branch": {"type": "string"},
        "worker_model": {"type": "string"}, "worker_reasoning_effort": {"type": "string"},
        "reviewer_model": {"type": "string"}, "reviewer_effort": {"type": "string"},
        "note": {"type": "string"},
    },
}
ATTEMPT_APPROVAL_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["spec_id", "spec_digest", "instance_id", "attempt", "approver", "risk_class",
                 "timestamp"],
    "properties": {
        "spec_id": {"type": "string", "minLength": 1},
        "spec_digest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "instance_id": {"type": "string", "pattern": "^[0-9a-f]{32}$"},
        "attempt": {"type": "integer", "minimum": 1},
        "approver": {"type": "string", "minLength": 1},
        "risk_class": {"enum": ["low", "default", "high"]},
        "timestamp": {"type": "string", "pattern": _TS_PATTERN},
        "note": {"type": "string"},
    },
}
def load_model_config() -> dict:
    """Load and validate scripts/models.json (R71). Fail closed on ANY error — a missing,
    unreadable, non-UTF-8, malformed, or invalid config refuses the launch with exit 2; nothing
    falls back to a hard-coded model. Validation lives in scripts/models_check.py, the ONE
    validator every consumer shares (round-1 review: the shell consumers must check the whole
    config, not one path — a second schema here would drift from theirs). Called once in
    cmd_launch(); the values are frozen into launch.json, so editing the config mid-run cannot
    change a running attempt (lc freeze semantics)."""
    try:
        spec = importlib.util.spec_from_file_location(
            "models_check", ROOT / "scripts" / "models_check.py")
        models_check = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(models_check)
    except Exception as exc:
        die(f"models validator missing or broken (scripts/models_check.py): {exc} — fail closed")
    try:
        raw = MODEL_CONFIG.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        die(f"models config missing or unreadable ({MODEL_CONFIG}): {exc} — fail closed")
    try:
        cfg = json.loads(raw)
    except json.JSONDecodeError as exc:
        die(f"models config is not valid JSON ({MODEL_CONFIG}): {exc} — fail closed")
    errs = models_check.validate(cfg)
    if errs:
        die(f"models config invalid ({MODEL_CONFIG}): " + "; ".join(errs))
    return cfg


def resolve_launch_models(approval: dict, cfg: dict) -> dict:
    """The launch-frozen model fields (R71), as ONE tested resolver: an approval's non-empty pin
    wins, otherwise the config default (`or`, not .get(default) — an empty-string pin falls back
    instead of being trusted). The alias map is always frozen from config.
    cmd_launch persists exactly this dict into launch.json, so a test asserts the precedence and
    freeze directly rather than inferring it from a full launch.

    Owner decision 2026-07-16: vendor pairing is the owner's call, made in scripts/models.json —
    nothing here polices same- vs cross-vendor. Two checks remain, both mechanical: every model
    in a runnable pairing must be DECLARED in vendor_map (an unmapped pin cannot be
    vendor-classified for authorship, so it is refused, not guessed), and the resolved reviewer
    may never be the SAME MODEL as the resolved worker ("nothing reviews its own work", CLAUDE.md
    rule 7 — a verdict from the weights that authored the diff is not a review)."""
    resolved = {
        "worker_model": approval.get("worker_model") or cfg["roles"]["worker"]["model"],
        "worker_effort": (approval.get("worker_reasoning_effort")
                          or cfg["roles"]["worker"]["effort"]),
        "reviewer_model": (approval.get("reviewer_model")
                           or cfg["roles"]["bound_reviewer"]["model"]),
        "reviewer_effort": (approval.get("reviewer_effort")
                            or cfg["roles"]["bound_reviewer"]["effort"]),
        "cli_aliases": cfg["cli_aliases"],
    }
    vm = cfg["vendor_map"]
    # R73 round-1 review (blocking): compare EFFECTIVE (alias-resolved) models, not config ids —
    # an alias pointing one model id at another would otherwise pass the distinct-id check while
    # the CLI invokes the worker's own weights. models_check refuses model-targeting aliases at
    # validation; this is the resolution-time backstop and also covers plain id equality.
    _eff = lambda m: resolved["cli_aliases"].get(m, m)
    if _eff(resolved["reviewer_model"]) == _eff(resolved["worker_model"]):
        die(f"launch refused: {resolved['worker_model']!r} would review its own work "
            f"(reviewer equals worker_model after alias resolution; nothing "
            f"reviews its own work, CLAUDE.md rule 7)")
    checked = [("worker_model", resolved["worker_model"]),
               ("reviewer_model", resolved["reviewer_model"])]
    for key, model in checked:
        if vm.get(model) is None:
            die(f"launch refused: {key} {model!r} is not declared in vendor_map "
                f"({MODEL_CONFIG}) — an undeclared model cannot be vendor-classified")
    # R73 Job 2 (supersedes the round-2 hard-wired codex check): the worker phase executes
    # through the worker-adapter registry pinned at dispatcher import — a vendor with no
    # registered worker adapter would resolve, freeze a truthful vendor, and then have no CLI
    # to execute under. Refuse it at resolution, before any side effects, not at run time.
    # Today the registry is codex-only; claude joins in R73 Job 3 (subagent worker runtime).
    if VENDOR_ADAPTERS is None:
        die(f"launch refused: vendor adapters failed to load at dispatcher start "
            f"({VENDOR_ADAPTERS_ERR}); fail closed")
    if vm[resolved["worker_model"]] not in VENDOR_ADAPTERS.worker_vendors():
        die(f"launch refused: worker_model {resolved['worker_model']!r} is "
            f"{vm[resolved['worker_model']]}-vendor, and no worker adapter exists for that "
            f"vendor (known: {'/'.join(VENDOR_ADAPTERS.worker_vendors())})")
    # R73 Job 1: vendors freeze WITH the models — run-time selects the CLI adapter from these
    # fields and never re-infers from a live config.
    resolved["worker_vendor"] = vm[resolved["worker_model"]]
    resolved["reviewer_vendor"] = vm[resolved["reviewer_model"]]
    # R73 Job 3: the execution MODE freezes with the vendor (registry-derived, never guessed):
    # external-cli workers run detached under the worker role envelope; subagent workers BUILD
    # inside the orchestrator session and are graded by `dispatch continue`. Frozen here so a
    # later registry or config change cannot re-mode an in-flight attempt.
    resolved["worker_mode"] = VENDOR_ADAPTERS.worker_mode(resolved["worker_vendor"])
    return resolved


VENV_PY = ROOT / ".venv" / "bin" / "python"
EXECUTION_POLICY = ROOT / "tests" / "execution-policy.tsv"
TEST_RUNTIME_ROOT = Path("/opt/orchestrator-test-runtime")
TEST_RUNTIME_PY = TEST_RUNTIME_ROOT / "bin" / "python"
EXECUTION_MODES = {"box-precondition", "candidate-isolated", "candidate-read"}

# Concurrency bound (Gate 3 part 3 mechanism: atomic slot claim + stale-base guard, unchanged).
# Configurable via ORCH_MAX_PARALLEL; default 3 (the operator, 2026-07-13). NOTE the real limiter is not the
# box — a worker is API-latency-bound (~200-300MB, mostly waiting on the model). It is the shared
# Codex/Claude quota + rate-limits, and the stale-base rebase churn that grows with parallelism. On
# THIS box (2 vCPU, 3.7GB, NO swap) 3 is safe for light specs; heavier real-product test suites/builds
# need more RAM/vCPU before raising this (no swap → OOM risk). Resize the box, then raise the env var.
try:
    MAX_PARALLEL = max(1, int(os.environ.get("ORCH_MAX_PARALLEL", "3")))
except ValueError:
    MAX_PARALLEL = 3
DEFAULT_CEILING_HOURS = 2.0

# Gate 4: remediation limits by risk_class. initial_attempt (attempt 1) is never a remediation.
# Only MERIT failures count toward the limit — interrupted/stale_base/error_launch are
# infrastructure outcomes and re-launch fresh without consuming remediation budget.
REMEDIATION_LIMITS = {"low": 5, "default": 3, "high": 1}
MERIT_FAILURES = {"failed_test", "failed_review", "failed_scope", "failed_integrity",
                  "failed_regression"}
ESCALATIONS = ORCH / "escalations"

# Terminal vs live attempt statuses.
TERMINAL = {
    "passed_pr_opened", "failed_worker_error", "failed_integrity",
    "failed_scope", "failed_test", "failed_review", "interrupted", "error_launch",
    "spec_blocked", "stale_base", "failed_remediation_exhausted", "failed_regression",
    # R73 Job 3: a subagent BUILD that outlived the launch-frozen absolute deadline (B6). The
    # BUILD ran in the orchestrator session, nothing was graded; relaunch as a fresh attempt.
    "error_timeout",
}
# awaiting_build is LIVE-without-a-unit (R73 Job 3): a subagent-mode attempt whose worktree and
# frozen launch record exist while the orchestrator session runs the BUILD. It counts against
# claim_slot's concurrency guards like any live attempt; reconcile expires it at the frozen
# deadline instead of treating a missing unit as a crash.
LIVE = {"launching", "running", "awaiting_build"}

# Structured error classes (Appendix A#7 / Gate 2 requirement).
ERR_AUTH = "auth"
ERR_QUOTA = "quota_rate_limit"
ERR_SANDBOX = "sandbox_denial"
ERR_TIMEOUT = "timeout"
ERR_INTEGRITY = "integrity"
ERR_TEST = "test"
ERR_TEST_NOT_RUN = "test_did_not_run"   # T1/R26: a required test SKIPped or produced no result
ERR_NO_ISOLATION = "isolation_unavailable"   # T2/R26: D5 absent and exposure not accepted
ERR_NO_ISOLATION_RC = 12                     # exit code for the refusal
ERR_SCOPE = "scope"
ERR_REVIEW = "review"
ERR_WORKER = "worker_nonzero"
ERR_LAUNCH = "launch"
# The sole owner-selected automation target. Workers build/test/review against it and PRs target it;
# only the owner promotes it to main (CLAUDE.md). An approval naming any other base is refused at
# preflight (B3) — never silently retargeted — so the reviewed base always equals the landed base.
AUTOMATION_BASE = "ready-for-main"
# Holistic-review takeaway #1 (SOL, 2026-07-13): an OPTIONAL regression-proof gate. A spec may declare
# a `regression_command` (+ `regression_test_paths`); the gate proves the change's new test actually
# CATCHES the intended defect — it must FAIL on the base (with the candidate's tests overlaid, so it
# fails for the right reason, not a missing file) and PASS on the candidate. A merit failure.
ERR_REGRESSION = "regression"
# Gate 3 part 3: the base branch advanced while this attempt ran (a sibling attempt integrated).
# The attempt was reviewed/tested against a base that is no longer the branch tip; integrating it
# would land a combination no gate ever saw. Terminal, not a merit failure: re-launch a fresh
# attempt off the new base (all gates re-run). Never hand-rebase a reviewed worktree.
ERR_STALE_BASE = "stale_base"
# policy-note item 2: worker signals the spec itself is unworkable; the old approval is void and a
# spec revision + new approval digest is required. Not a worker failure.
ERR_SPEC_BLOCKED = "spec_blocked"
# Gate 4: remediation budget exhausted or findings repeating without material change — the spec is
# failed and escalated with the full evidence trail. Never an infinite loop, never silent success.
ERR_REMEDIATION = "remediation_exhausted"
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


# B4 finding 4: a planted `refs/replace/<oid>` transparently swaps a replacement tree/blob under
# EVERY object read (git show/ls-tree/diff/cat-file) while `rev-parse HEAD` still reports the
# original, attested commit hash — so enumeration and blob reads would grade replacement content
# labelled as the real commit. `--no-replace-objects` + GIT_NO_REPLACE_OBJECTS=1 disable that
# substitution. We apply them to the ONE git wrapper every call routes through, so no pinned read
# can forget them; it is harmless for write commands (replace refs only affect object resolution).
_GIT_READ_ENV = {"GIT_NO_REPLACE_OBJECTS": "1"}


def _git_env() -> dict:
    return {**os.environ, **_GIT_READ_ENV}


def git(*args, cwd=ROOT, check=True):
    cp = run(["git", "--no-replace-objects", *args], cwd=str(cwd), env=_git_env())
    if check and cp.returncode != 0:
        die(f"git {' '.join(args)} failed: {cp.stderr.strip()}")
    return cp.stdout.strip()


def git_cp(args, cwd=ROOT, text=True):
    """CompletedProcess for a git command that READS object/graph data, with replace-objects
    disabled (finding 4). Every pinned/object-reading git call that needs the raw returncode/bytes
    (blob reads, tree enumeration, ancestry in integrity(), the diff scope_check() parses) routes
    through here or through git() — so a planted refs/replace cannot alter what any gate sees."""
    return run(["git", "--no-replace-objects", *args], cwd=str(cwd),
               capture_output=True, text=text, env=_git_env())


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ------------------------------------------------------------- B4: pinned-git grading ----
# H4/B4 (codex-audit-2026-07-15): the required test set, the manifest, and every test's bytes
# used to be read from the FILESYSTEM working tree and merely LABELED with the HEAD commit — a
# dirty, deleted, or untracked tests/*.sh file could silently shrink/grow/poison the "installed"
# suite while the attestation still stamped it as commit HEAD. Fix: enumerate/hash/read from the
# PINNED GIT TREE (git ls-tree/git show <commit>), never Path.glob/read_bytes on tests/, and
# refuse to grade at all if the working tree has drifted from that commit (grader_drift below).
def git_show_bytes(commit: str, rel: str, cwd: Path = ROOT) -> bytes:
    """Exact bytes of the committed blob at `commit`:`rel` — never the working-tree file. Reads
    with replace-objects disabled (finding 4) so a planted replacement blob cannot be returned."""
    cp = git_cp(["show", f"{commit}:{rel}"], cwd=cwd, text=False)
    if cp.returncode != 0:
        stderr = (cp.stderr or b"").decode("utf-8", "replace")
        raise ValueError(f"git show {commit}:{rel} failed: {stderr.strip()}")
    return cp.stdout


def git_ls_tree_sh(commit: str, subdir: str, cwd: Path = ROOT) -> list[tuple[str, str, str]]:
    """(mode, type, path) for every *.sh entry directly inside subdir/ at commit — non-recursive,
    matching the old tests_dir.glob('*.sh') semantics (direct children only, not descended
    subdirectories). Includes symlinks/non-blobs so the caller can fail closed on them explicitly,
    the same way the old code refused a symlinked test file. Replace-objects disabled (finding 4)."""
    cp = git_cp(["ls-tree", "-z", commit, "--", f"{subdir}/"], cwd=cwd)
    if cp.returncode != 0:
        raise ValueError(f"git ls-tree {commit} -- {subdir}/ failed: {cp.stderr.strip()}")
    out = []
    for entry in cp.stdout.split("\x00"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        fields = meta.split()
        if len(fields) != 3 or not path.endswith(".sh"):
            continue
        mode, otype, _blob = fields
        out.append((mode, otype, path))
    return sorted(out, key=lambda t: t[2])


def committed_entry(commit: str, rel: str, cwd: Path = ROOT) -> tuple[str, str] | None:
    """(mode, type) of the tree entry at exactly `commit`:`rel`, or None if absent. Used to prove a
    committed grader input is a REGULAR blob (mode 100644/100755) and not a symlink (120000),
    gitlink, or tree — finding 5: git show would happily hand back a symlink's target-path text as
    'manifest' bytes. Replace-objects disabled (finding 4)."""
    cp = git_cp(["ls-tree", "-z", commit, "--", rel], cwd=cwd)
    if cp.returncode != 0:
        return None
    for entry in cp.stdout.split("\x00"):
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        fields = meta.split()
        if len(fields) == 3 and path == rel:
            return fields[0], fields[1]   # (mode, type)
    return None


def _is_regular_blob(meta: tuple[str, str] | None) -> bool:
    return meta is not None and meta[1] == "blob" and meta[0] in ("100644", "100755")


def grader_drift(commit: str, root: Path = ROOT) -> list[str]:
    """One description per grader-relevant difference between the working tree and `commit` —
    empty means every path the grader reads (scripts/test, scripts/requirements.txt,
    tests/execution-policy.tsv, tests/*.sh) is present on disk as a regular non-symlink file whose
    BYTES are identical to the committed blob, with no extra tests/*.sh shadowing the committed
    suite. Callers MUST refuse to grade (fail closed) on any non-empty result (B4).

    scripts/requirements.txt is here (round-3): trusted_test_runtime() hashes ROOT/scripts/
    requirements.txt off the working tree to decide which dependency closure is authorized, so a
    dirty requirements.txt could otherwise vouch for a different set of installed deps without
    tripping any gate.

    Finding 3: this does NOT use `git diff`/`git status` as a byte-identity oracle. Those consult
    git's index and stat cache, which `assume-unchanged`/`skip-worktree` deliberately suppress, and
    a staged-then-reverted change can net to 'clean'. Instead we read the committed blob bytes
    (via git show, replace-objects off) and the working-tree bytes DIRECTLY off disk and compare
    them — plus type and executable-mode — so nothing git's index says can hide a real difference."""
    problems: list[str] = []
    committed: dict[str, bytes] = {}     # rel -> committed blob bytes (the grader files)

    def _add_committed(rel: str) -> None:
        meta = committed_entry(commit, rel, cwd=root)
        if meta is None:
            problems.append(f"grader input missing from commit {commit}: {rel}")
            return
        if not _is_regular_blob(meta):
            problems.append(f"grader input is not a regular file at {commit}: {rel} "
                            f"(mode {meta[0]}, type {meta[1]})")
            return
        committed[rel] = git_show_bytes(commit, rel, cwd=root)

    _add_committed("scripts/test")
    _add_committed("scripts/requirements.txt")
    _add_committed("tests/execution-policy.tsv")
    for mode, otype, path in git_ls_tree_sh(commit, "tests", cwd=root):
        if otype != "blob" or mode not in ("100644", "100755"):
            problems.append(f"required test is not a regular non-symlink file at {commit}: {path} "
                            f"(mode {mode}, type {otype})")
            continue
        committed[path] = git_show_bytes(commit, path, cwd=root)

    for rel, want in committed.items():
        p = root / rel
        try:
            st = p.lstat()
        except OSError:
            problems.append(f"grader input committed at {commit} but missing on disk: {rel}")
            continue
        if stat_module.S_ISLNK(st.st_mode) or not stat_module.S_ISREG(st.st_mode):
            problems.append(f"grader path on disk is a symlink or non-regular file: {rel}")
            continue
        try:
            got = p.read_bytes()
        except OSError as e:
            problems.append(f"grader input unreadable on disk: {rel}: {e}")
            continue
        if got != want:
            problems.append(f"working-tree bytes differ from commit {commit}: {rel}")
        # mode drift: committed executables must stay executable and vice-versa (finding 3)
        disk_exec = bool(st.st_mode & 0o111)
        # rel's committed mode: 100755 for the tests (from ls-tree) / re-check scripts+manifest
        meta = committed_entry(commit, rel, cwd=root)
        want_exec = bool(meta and meta[0] == "100755")
        if disk_exec != want_exec:
            problems.append(f"working-tree mode differs from commit {commit}: {rel} "
                            f"(disk {'exec' if disk_exec else 'non-exec'}, "
                            f"commit {'exec' if want_exec else 'non-exec'})")

    # An untracked/extra tests/*.sh that is NOT in the committed suite would still be run by
    # `scripts/test`'s own `tests/*.sh` glob at integration time — refuse it (untracked-shadowing).
    tests_dir = root / "tests"
    try:
        disk_sh = sorted(tests_dir.glob("*.sh"))
    except OSError:
        disk_sh = []
    for p in disk_sh:
        rel = str(p.relative_to(root))
        if p.is_symlink() or not p.is_file():
            problems.append(f"tests/ entry on disk is a symlink or non-regular file: {rel}")
        elif rel not in committed:
            problems.append(f"untracked test shadowing the committed suite: {rel}")
    return problems


@contextlib.contextmanager
def materialized_grader_tree(commit: str, root: Path = ROOT):
    """Yield a FRESH checkout of `commit` in a directory OUTSIDE the repo working tree, from which
    all operator-side graders are executed and hashed (findings 1+2, round 2).

    Executing any grader from a path under the mutable working tree is an irreducible pathname-race:
    a same-uid process can rename the committed inode aside, swap in a hostile script, and restore
    the name before our after-hash — 0500 does not stop the owner. The round-1 dotfile-under-tests/
    approach also regressed grader_drift (Path.glob('*.sh') matches dotfiles). So we materialize the
    ENTIRE committed tree via a detached `git worktree` at a private temp path: every grader AND its
    data dependencies (scripts/dispatch.py for codex_runtime.sh, tests/banned-terms.txt for
    plain_language.sh, ...) come out byte-identical to `commit`, with a working .git so git-based
    graders still function and the shared object store still resolves the candidate commit. No
    grading execution ever opens a path under the working tree the worker/operator is mutating, and
    nothing is written under tests/. Files are stripped of write bits to narrow — not close — the
    residual same-uid race on this temp tree itself; that residual is the KNOWN deferred limitation
    tracked as SECURITY.md gap 3 / BACKLOG item 6 ("move the grade fully outside candidate/operator
    influence"), NOT part of B4. Removed on exit."""
    holder = Path(tempfile.mkdtemp(prefix="orch-grader-"))
    wt = holder / "tree"
    cp = git_cp(["worktree", "add", "--quiet", "--detach", str(wt), commit], cwd=root)
    if cp.returncode != 0:
        shutil.rmtree(holder, ignore_errors=True)
        raise ValueError(f"could not materialize grader tree at {commit}: {cp.stderr.strip()}")
    try:
        for p in wt.rglob("*"):        # drop write bits from regular files (dirs stay writable
            try:                       # so cleanup can unlink; parent-dir write is what unlink needs)
                st = p.lstat()
                if stat_module.S_ISREG(st.st_mode):
                    p.chmod(st.st_mode & ~0o222)
            except OSError:
                pass
        yield wt
    finally:
        run(["git", "worktree", "remove", "--force", str(wt)], cwd=str(root), env=_git_env())
        shutil.rmtree(holder, ignore_errors=True)


def _grader_run_path(gtree: Path, rel: str) -> Path:
    """The pinned, out-of-working-tree path to execute for grader `rel` (finding 2)."""
    return gtree / rel


def integration_grade_gate(root: Path = ROOT) -> tuple[str, list[str]]:
    """Finding 1 — the post-merge integration gate. Returns (merged_commit, drift_problems).

    cmd_integrate re-runs the installed `./scripts/test` after each merge, but that runner globs and
    executes the FILESYSTEM `tests/*.sh` + `scripts/test`. If the working tree has drifted from the
    commit that just landed (a dirty/replaced scripts/test, altered manifest, deleted tracked test,
    or untracked tests/*.sh), the suite would grade code the post-merge commit does not contain.
    Resolve the merged commit and require grader_drift() empty before grading; the caller escalates
    (never grades) on any non-empty result, exactly like launch and the candidate phases."""
    commit = git("rev-parse", "HEAD", cwd=root)
    return commit, grader_drift(commit, root)


def execution_policy(root: Path = ROOT, commit: str | None = None) -> dict:
    """Parse the sole execution-mode manifest and derive the all-installed-tests required set —
    from the PINNED GIT COMMIT tree, never the working directory (B4 fix). The required set, the
    manifest text, and every required test's bytes are all read with `git ls-tree`/`git show
    <commit>:<path>`; a working-tree file that is dirty, deleted, or untracked cannot shrink,
    grow, or poison the suite that gets attested against `commit`. Callers MUST call
    grader_drift(commit) first and refuse to grade on any drift — this function reads the pinned
    tree only and does not itself compare against the working tree.

    Entries assign modes; they never select tests. Missing/malformed/duplicate/unsafe/nonexistent
    entries and an empty installed suite fail closed. Unlisted tests are candidate-isolated.
    """
    if commit is None:
        cp = run(["git", "--no-replace-objects", "rev-parse", "HEAD"], cwd=str(root),
                 env=_git_env())
        if cp.returncode != 0:
            raise ValueError(f"cannot resolve HEAD of {root}: {cp.stderr.strip()}")
        commit = cp.stdout.strip()
    manifest_rel = "tests/execution-policy.tsv"
    # Finding 5: reject a committed symlink/non-regular manifest — git show would otherwise return a
    # symlink's target-path string and we would parse THAT as policy text. The old filesystem code
    # rejected symlinks/non-regular files; the pinned-tree read must too, for the manifest AND (in
    # git_ls_tree_sh below) every required test blob.
    if not _is_regular_blob(committed_entry(commit, manifest_rel, cwd=root)):
        raise ValueError(f"execution policy is not a regular committed file at {commit}: "
                         f"{manifest_rel} (symlink or non-blob rejected)")
    try:
        manifest_bytes = git_show_bytes(commit, manifest_rel, cwd=root)
    except ValueError as e:
        raise ValueError(f"execution policy unreadable at {commit}: {e}") from e
    try:
        text = manifest_bytes.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ValueError(f"execution policy is not valid UTF-8 at {commit}: {e}") from e
    if "\r" in text:
        raise ValueError("execution policy contains non-normalized CR characters")
    entries = git_ls_tree_sh(commit, "tests", cwd=root)
    for mode, otype, path in entries:
        if otype != "blob" or mode not in ("100644", "100755"):
            raise ValueError(f"required test is not a regular non-symlink file at {commit}: {path}")
    required = [path for _, _, path in entries]
    if not required:
        raise ValueError("required test set is empty")
    installed = set(required)
    modes = {rel: "candidate-isolated" for rel in required}
    seen: set[str] = set()
    for line_no, line in enumerate(text.splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            raise ValueError(f"execution policy line {line_no} must have exactly three TSV fields")
        rel, mode, rationale = fields
        if not re.fullmatch(r"tests/[A-Za-z0-9_.-]+\.sh", rel):
            raise ValueError(f"execution policy line {line_no} has unsafe path {rel!r}")
        if rel not in installed:
            raise ValueError(f"execution policy line {line_no} names nonexistent test {rel!r}")
        if rel in seen:
            raise ValueError(f"execution policy line {line_no} duplicates {rel!r}")
        if mode not in EXECUTION_MODES:
            raise ValueError(f"execution policy line {line_no} has unknown mode {mode!r}")
        if not rationale.strip():
            raise ValueError(f"execution policy line {line_no} has an empty rationale")
        seen.add(rel)
        modes[rel] = mode
    # No fixed mode COUNTS (frozen design #2/#4): every installed test is required, the manifest
    # ASSIGNS modes, and unlisted tests default to candidate-isolated — counts are re-measured, not
    # pinned. A hardcoded "exactly two box + two read" would fail-close a legitimate future manifest.
    test_hashes = {}
    for rel in required:
        try:
            test_hashes[rel] = hashlib.sha256(git_show_bytes(commit, rel, cwd=root)).hexdigest()
        except ValueError as e:
            raise ValueError(f"required test unreadable at {commit}: {rel}: {e}") from e
    return {"authority": "installed" if root.resolve() == ROOT.resolve() else "candidate",
            "manifest_path": manifest_rel, "installed_commit": commit,
            "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(), "required": required,
            "modes": modes, "test_sha256": test_hashes}


# --------------------------------------------------------------- atomic io ----
def atomic_write(path: Path, data) -> None:
    """Accepts str (text mode) or bytes (binary mode, used for byte-exact spec snapshots)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    binary = isinstance(data, (bytes, bytearray))
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "wb" if binary else "w") as fh:
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
    """Best-effort read of canonical attempt states for reporting/reconcile flows.

    Skips advisory *.health.json sidecars and any non-object JSON value (owner-extension round-1:
    a canonical file holding e.g. a bare string crashed cmd_reconcile at st.get() before its
    malformed-state scan could report it). Silent-skip is safe HERE because the two consumers
    fail loudly elsewhere: claim_slot dies on malformed canonical state before any launch, and
    cmd_reconcile separately scans and REPORTS malformed canonical files."""
    if not STATE.exists():
        return []
    out = []
    for p in STATE.glob("*.json"):
        if p.name.endswith(".health.json"):
            continue
        try:
            parsed = json.loads(p.read_text())
        except Exception:
            continue
        if isinstance(parsed, dict):
            out.append(parsed)
    return out


# ----------------------------------------------------------- spec/approval ----
def spec_path(spec_id: str) -> Path:
    return SPECS / f"{spec_id}.yaml"


def spec_digest(spec_id: str) -> str:
    return hashlib.sha256(spec_path(spec_id).read_bytes()).hexdigest()


# ------------------------------------------------------------ spec snapshot ---
# B2 (audit 2026-07-15): the approved digest was verified once at preflight and frozen into
# launch.json, but the worker prompt, reviewer prompt, and merge gate all re-read the LIVE,
# mutable spec file — so editing specs/<id>.yaml after approval silently changed what got built,
# what the reviewer judged, and what risk_class/needs_network the merge gate read, while
# provenance still showed the original approved digest. Fix: freeze the exact approved bytes into
# the attempt at launch and read ONLY that snapshot everywhere downstream.
def spec_snapshot_path(att: Path) -> Path:
    return att / "spec-snapshot.yaml"


def verify_spec_bytes(path: Path, expected_digest: str, label: str, code: int) -> tuple[bytes, dict]:
    """The one and only way a spec (a snapshot OR a live file) is consumed anywhere downstream.
    Read the bytes ONCE, hash exactly THOSE bytes, verify the hash equals the recorded/approved
    digest, and parse THOSE SAME bytes — never hash one read and trust a second read (that is the
    TOCTOU the audit's B2 findings 1 and 3 flagged). Returns (bytes, parsed_mapping); dies (fail
    closed) on any read/digest/parse error. `code` is the process exit code for the refusal."""
    try:
        data = path.read_bytes()
    except OSError as e:
        die(f"{label} unreadable ({e}); refuse.", code)
    digest = hashlib.sha256(data).hexdigest()
    if digest != expected_digest:
        die(f"{label} digest {digest[:12]}… != approved/recorded {expected_digest[:12]}…; the "
            f"bytes were changed after approval; refuse.", code)
    try:
        parsed = yaml.safe_load(data)
    except yaml.YAMLError as e:
        die(f"{label} YAML parse error: {e}; refuse.", code)
    if not isinstance(parsed, dict):
        die(f"{label} is not a mapping; refuse.", code)
    return data, parsed


def write_spec_snapshot(att: Path, data: bytes, approved_digest: str) -> str:
    """Freeze the EXACT approved spec bytes (the single buffer preflight already read, hashed, and
    parsed) into the attempt directory. Takes the bytes in memory and never re-opens the live file —
    that is the whole point (B2 round-2 finding 1: no read-vs-hash-vs-snapshot TOCTOU). Asserts the
    buffer still hashes to the approved digest as a defensive invariant, then writes it."""
    digest = hashlib.sha256(data).hexdigest()
    if digest != approved_digest:   # can only fire if a caller passed mismatched (bytes, digest)
        die(f"internal: snapshot bytes hash {digest} != approved digest {approved_digest}; refuse.", 6)
    atomic_write(spec_snapshot_path(att), data)
    return digest


def snapshot_spec(att: Path, expected_digest: str) -> dict:
    """The frozen, verified spec mapping every downstream consumer (worker prompt, reviewer prompt,
    PR title, merge gate) must use — never a fresh read of the live file (B2). Re-hashes the
    snapshot bytes on EVERY consumption and refuses if they drifted from the recorded digest (B2
    finding 1: existence is not integrity — editing spec-snapshot.yaml after launch must not feed
    unapproved bytes anywhere). Absence is fatal; there is no fall-back to the live spec."""
    p = spec_snapshot_path(att)
    if not p.exists():
        die(f"no spec snapshot at {p}; refuse to consume the live spec file.", 6)
    _data, parsed = verify_spec_bytes(p, expected_digest, f"spec snapshot {p}", 6)
    return parsed


def snapshot_spec_text(att: Path, expected_digest: str) -> str:
    """The frozen spec TEXT for the worker/reviewer prompts — same verified read as snapshot_spec,
    returning the exact bytes decoded (so the prompt shows byte-for-byte what was approved)."""
    p = spec_snapshot_path(att)
    if not p.exists():
        die(f"no spec snapshot at {p}; refuse to build a prompt from the live spec file.", 6)
    data, _ = verify_spec_bytes(p, expected_digest, f"spec snapshot {p}", 6)
    return data.decode("utf-8")


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


def validate_spec_dict(spec: dict, spec_id: str) -> list[str]:
    """Schema + cross-field validation of an ALREADY-PARSED spec mapping. Takes the parse so the
    caller controls how many times the file is read (preflight reads it exactly once — B2 round-2)."""
    schema = json.loads(SPEC_SCHEMA.read_text())
    errors = [f"{'/'.join(map(str, e.path)) or '<root>'}: {e.message}"
              for e in Draft202012Validator(schema).iter_errors(spec)]
    if spec.get("id") != spec_id:
        errors.append(f"id field '{spec.get('id')}' != filename stem '{spec_id}'")
    if spec.get("regression_command") and not spec.get("regression_test_paths"):
        errors.append("regression_command requires non-empty regression_test_paths (the test files to "
                      "overlay onto the base, so the base run fails for the right reason).")
    return errors


def validate_spec(spec_id: str) -> tuple[dict, list[str]]:
    """Return (spec, errors). Errors empty => schema-valid. Convenience wrapper around a fresh read;
    the launch path uses read_approved_spec() instead so it reads the file exactly once."""
    spec = load_spec(spec_id)
    return spec, validate_spec_dict(spec, spec_id)


def read_approved_spec(spec_id: str) -> tuple[bytes, str, dict, list[str]]:
    """THE single source of truth for a launch: read specs/<id>.yaml exactly ONCE and derive the
    digest (hash of these exact bytes), the parsed mapping, and validation errors all from that one
    buffer. No launch code path may re-open the file afterward — a second read is the read-vs-hash-
    vs-parse-vs-snapshot TOCTOU the audit's B2 round-2 finding 1 flagged (a swap between reads could
    bind version A's needs_network/depends_on/risk/test_command/ceiling to version B's snapshotted
    bytes). Returns (bytes, digest, parsed, errors); parsed is {} when the bytes don't parse to a
    mapping (errors is then non-empty)."""
    p = spec_path(spec_id)
    if not p.exists():
        die(f"spec not found: {p}", 4)
    try:
        data = p.read_bytes()
    except OSError as e:
        die(f"spec unreadable: {p}: {e}", 4)
    digest = hashlib.sha256(data).hexdigest()
    try:
        parsed = yaml.safe_load(data)
    except yaml.YAMLError as e:
        return data, digest, {}, [f"YAML parse error: {e}"]
    if not isinstance(parsed, dict):
        return data, digest, {}, ["spec is not a mapping"]
    return data, digest, parsed, validate_spec_dict(parsed, spec_id)


INSTANCE = ORCH / "instance.json"   # gitignored: this operator instance's identity


def instance_identity() -> dict | None:
    """Per-instance identity (id + repo). Gitignored, so it NEVER travels with a clone/template —
    which is exactly what lets us reject copied approvals (SOL, SHARE decision)."""
    if not INSTANCE.exists():
        return None
    try:
        return json.loads(INSTANCE.read_text())
    except Exception:
        return None


def ensure_instance() -> dict:
    """Create the instance identity if absent (random id bound to the git origin). Called lazily so
    an existing operator gets one on first launch; init-operator generates a fresh one for newcomers."""
    inst = instance_identity()
    if inst:
        return inst
    import secrets
    origin = run(["git", "remote", "get-url", "origin"], cwd=str(ROOT)).stdout.strip()
    inst = {"instance_id": secrets.token_hex(16), "repo": origin, "created": now()}
    atomic_write(INSTANCE, json.dumps(inst, indent=2))
    return inst


def approval_for(digest: str) -> dict | None:
    p = APPROVALS / f"{digest}.json"
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except Exception:
        die(f"approval artifact {p.name} is not valid JSON; refuse.", 6)


def _validate_approval(obj: dict, schema: dict, label: str, code: int) -> None:
    """Schema-validate an approval artifact (B1). Fail-closed: any shape error refuses the launch."""
    errs = [("/".join(str(x) for x in e.path) + ": " if e.path else "") + e.message
            for e in Draft202012Validator(schema).iter_errors(obj)]
    if errs:
        die(f"{label} schema-invalid:\n  - " + "\n  - ".join(errs), code)


def preflight(spec_id: str) -> dict:
    """
    All the validation-first gates. Returns a context dict on success; dies with a
    structured message otherwise. This is refused-before-launch policy.
    """
    if HALT.exists():
        die(f"HALT present ({HALT}); all launches blocked. Remove it to resume.", 3)

    # B2 round-2 finding 1: read the approved spec's bytes exactly ONCE. digest, parse, validation,
    # and (in cmd_launch) the snapshot all come from THIS single buffer — never a second open of
    # specs/<id>.yaml. Everything downstream (needs_network refusal, depends_on, remediation risk,
    # test_command, regression gate, ceiling) reads `spec`, which is the parse of these exact bytes.
    spec_bytes, digest, spec, errors = read_approved_spec(spec_id)
    if errors:
        die("spec schema-invalid:\n  - " + "\n  - ".join(errors), 4)

    # needs_network hard-refused (the operator decision, residual risk 13-B).
    if spec.get("needs_network", False):
        die("needs_network:true is REFUSED on this host: the Codex sandbox cannot restrict "
            "reads (risk 13-B), so a networked worker could exfiltrate credentials. Requires "
            "the dedicated worker user/container (D5 endgame) first.", 5)

    approval = approval_for(digest)
    if approval is None:
        die(f"no approval artifact for digest {digest} (spec unapproved or edited since "
            f"approval). Expected {APPROVALS / (digest + '.json')}.", 6)
    _validate_approval(approval, APPROVAL_SCHEMA, f"approval {digest[:12]}…", 6)
    if approval.get("spec_digest") != digest:
        die("approval artifact's spec_digest does not match the current spec file.", 6)
    # Bind to the launching spec by id, not digest alone (B1): a digest collision or a copied
    # artifact must not authorize a different spec.
    if approval.get("spec_id") != spec_id:
        die(f"approval spec_id={approval.get('spec_id')!r} != launching spec {spec_id!r}; refuse.", 6)
    # Bind risk to the spec (B1 round-2): the approval's risk_class must match the spec's, so an
    # approval cannot silently under-declare risk relative to what the spec now says.
    if approval.get("risk_class") != spec.get("risk_class"):
        die(f"approval risk_class={approval.get('risk_class')!r} != spec risk_class "
            f"{spec.get('risk_class')!r}; refuse.", 6)
    # Approved scope may not be BROADER than what the spec itself declares in_scope (B1). Glob-subset
    # across arbitrary patterns is unsafe to infer, so require the conservative, provable relation:
    # every approved glob must appear verbatim in the spec's in_scope. Anything else is refused.
    spec_scope = set(spec.get("in_scope", []))
    broader = [g for g in approval.get("approved_scope", []) if g not in spec_scope]
    if broader:
        die(f"approval approved_scope contains globs not in the spec's in_scope (broader than the "
            f"spec authorizes): {broader}; refuse.", 6)

    # Instance binding (SOL, SHARE decision): an approval only authorizes on the instance that
    # created it. A digest matches identical spec text anywhere, so digest-only approval would let a
    # CLONED repo's copied approvals authorize copied specs. instance.json is gitignored (never
    # travels with a clone), so a copied approval's instance_id can't match a fresh clone's. Fail
    # closed: no instance, or a mismatch, refuses the launch.
    inst = ensure_instance()
    if approval.get("instance_id") != inst["instance_id"]:
        die(f"approval is not bound to this instance ({inst['instance_id'][:12]}…): approval "
            f"instance_id={str(approval.get('instance_id'))[:12]}…. A copied approval cannot "
            f"authorize a spec here — re-approve on this instance.", 6)

    # Base pin (B3): the whole pipeline — fetch, worktree, scope, regression, review binding,
    # stale-base guard, auto-merge — reads approval.base_branch, but PR creation hardcoded
    # 'ready-for-main'. An approval naming any other base would be built/tested/reviewed against that
    # base yet land a PR on ready-for-main. Refuse a non-target base here, before any fetch/worktree/
    # PR, so the reviewed base always equals the landed base.
    appr_base = approval.get("base_branch", AUTOMATION_BASE)
    if appr_base != AUTOMATION_BASE:
        die(f"approval base_branch={appr_base!r} is not the automation target {AUTOMATION_BASE!r}; "
            f"refuse (re-approve against {AUTOMATION_BASE}).", 6)

    # depends_on all done.
    for dep in spec.get("depends_on", []):
        st = read_state(dep)
        if not st or st.get("status") != "passed_pr_opened":
            die(f"dependency {dep} not satisfied (state="
                f"{st.get('status') if st else 'none'}).", 7)

    # Advisory (R88): overlap with another pending spec is a serialization hint for the operator,
    # never a refusal — the binding scope gate stays in scope_check.
    _warn_scope_overlaps(spec_id, spec.get("in_scope", []), spec.get("depends_on", []))

    # NOTE: the MAX_PARALLEL concurrency check is NOT here — it must be atomic with the state
    # write so two concurrent launches cannot both pass it. See claim_slot(), called from
    # cmd_launch under the STATE lock.
    # spec_bytes is the exact buffer that produced `digest` and `spec`; cmd_launch snapshots THESE
    # bytes (never a re-read), so the snapshot, its digest, and the recorded metadata are one spec.
    return {"spec": spec, "digest": digest, "approval": approval, "spec_bytes": spec_bytes}


def claim_slot(spec_id: str, launching_state: dict) -> None:
    """Atomically enforce concurrency limits and record the 'launching' state, all under ONE
    STATE lock so parallel launches (Gate 3 part 3) cannot over-subscribe. Two guards:
      1. One spec has at most one live attempt at a time (attempts of a spec are sequential).
         State files are keyed per-spec, so a second live attempt would clobber the first's
         state — refuse it.
      2. At most MAX_PARALLEL live attempts across all specs.
    Dies with exit 8 if either is violated. On success the durable 'launching' record exists
    before any unit starts (Appendix A: no untraceable launches)."""
    STATE.mkdir(parents=True, exist_ok=True)
    lock = STATE / ".lock"
    with open(lock, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            states = []
            for p in STATE.glob("*.json"):
                if p.name.endswith(".health.json"):
                    continue  # advisory health snapshot, never attempt state (B10 round-2)
                try:
                    parsed = json.loads(p.read_text())
                except Exception as e:
                    # B10: a malformed canonical state file may BE a live attempt (truncated
                    # write, mid-crash). Silently skipping it removes that attempt from the
                    # same-spec and MAX_PARALLEL checks — fail the claim instead of guessing.
                    die(f"state file {p} is unreadable ({e}); run `dispatch reconcile` — it "
                        f"reports malformed state — and resolve it before launching (a "
                        f"malformed live attempt must not vanish from concurrency checks).", 8)
                if not isinstance(parsed, dict):
                    die(f"state file {p} holds a non-object JSON value; run `dispatch "
                        f"reconcile` and resolve it before launching (B10).", 8)
                states.append(parsed)
            live = [s for s in states if s.get("status") in LIVE]
            same = [s.get("attempt_id") for s in live if s.get("spec_id") == spec_id]
            if same:
                die(f"{spec_id} already has a live attempt {same}; attempts of one spec are "
                    f"sequential (its state file is per-spec).", 8)
            if len(live) >= MAX_PARALLEL:
                die(f"MAX_PARALLEL={MAX_PARALLEL} reached; live attempt(s): "
                    f"{[s.get('attempt_id') for s in live]}.", 8)
            atomic_write(STATE / f"{spec_id}.json",
                         json.dumps({**launching_state, "updated": now()}, indent=2))
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


# ------------------------------------------------------- remediation (G4) ----
def merit_failed_attempts(spec_id: str) -> list[tuple[int, dict]]:
    """Prior attempts of this spec that ended in a MERIT failure (ascending attempt order).
    Infrastructure endings (interrupted, stale_base, error_launch, spec_blocked) don't count."""
    d = ATTEMPTS / spec_id
    out = []
    if not d.exists():
        return out
    for p in sorted((q for q in d.iterdir() if q.name.isdigit()), key=lambda q: int(q.name)):
        rp = p / "result.json"
        if rp.exists():
            try:
                r = json.loads(rp.read_text())
            except Exception:
                continue
            if r.get("status") in MERIT_FAILURES:
                out.append((int(p.name), r))
    return out


def findings_of(spec_id: str, n: int, result: dict) -> dict:
    """Extract the SPECIFIC findings a remediation must address, from attempt n's evidence."""
    att = ATTEMPTS / spec_id / str(n)
    status = result.get("status")
    f: dict = {"failed_attempt": n, "status": status}
    if status == "failed_review":
        rv = att / "review.json"
        if rv.exists():
            try:
                v = json.loads(rv.read_text())
                f["reviewer_reasons"] = v.get("reasons", [])
                f["unmet_criteria"] = [c for c in v.get("criteria", [])
                                       if c.get("result") != "MET"]
                f["scope_finding"] = v.get("scope_finding")
                f["security_findings"] = v.get("security_findings")
            except Exception:
                f["reviewer_reasons"] = ["review.json unreadable"]
    elif status == "failed_test":
        tl = att / "test.log"
        if tl.exists():
            f["test_log_tail"] = tl.read_text()[-2000:]
        f["test_exit"] = result.get("test_exit")
    elif status == "failed_scope":
        sc = att / "scope.json"
        if sc.exists():
            try:
                f["out_of_scope_paths"] = json.loads(sc.read_text()).get("out_of_scope", [])
            except Exception:
                pass
    elif status == "failed_integrity":
        f["integrity"] = result.get("integrity") or result.get("detail")
    return f


def _findings_key(f: dict) -> str:
    """Canonical form for the repeated-identical-findings stop-early check."""
    core = {k: f.get(k) for k in ("status", "reviewer_reasons", "unmet_criteria",
                                  "out_of_scope_paths", "test_exit")}
    return json.dumps(core, sort_keys=True)


def escalate(spec_id: str, reason: str, evidence: dict) -> Path:
    """Durable escalation record (tracked provenance). Gate 4: limit exhausted / stop-early →
    spec failed + escalation with the evidence trail. the operator reviews after the fact."""
    ESCALATIONS.mkdir(parents=True, exist_ok=True)
    path = ESCALATIONS / f"{spec_id}-{now().replace(':', '').replace('-', '')}.json"
    atomic_write(path, json.dumps({"spec_id": spec_id, "reason": reason,
                                   "evidence": evidence, "created": now()}, indent=2))
    return path


def remediation_preflight(spec_id: str, spec: dict, digest: str, n: int) -> dict | None:
    """Gate 4 remediation gate, applied at launch of attempt n. Returns the remediation context
    to embed in launch.json (None for a non-remediation launch). Dies (and records the failed/
    escalated state) if the budget is exhausted or findings are repeating."""
    fails = merit_failed_attempts(spec_id)
    k = len(fails)
    risk = spec.get("risk_class", "default")

    # High-risk specs require the operator's explicit approval before EVERY dispatch, at every autonomy
    # level (Gate 4 §2) — a per-attempt artifact next to the spec approval, never implied.
    if risk == "high":
        pa = APPROVALS / f"{digest}.attempt-{n}.json"
        if not pa.exists():
            die(f"high-risk spec: attempt {n} needs the operator's per-dispatch approval artifact "
                f"({pa}); refusing to launch.", 17)
        # B1: existence is not authorization. Parse + schema-validate + bind to this
        # spec/instance/attempt — an empty or mismatched file must NOT authorize a high-risk dispatch.
        try:
            pa_obj = json.loads(pa.read_text())
        except Exception:
            die(f"per-dispatch approval {pa.name} is not valid JSON; refuse.", 17)
        _validate_approval(pa_obj, ATTEMPT_APPROVAL_SCHEMA, f"per-dispatch approval {pa.name}", 17)
        pa_inst = ensure_instance()
        if pa_obj.get("spec_digest") != digest:
            die(f"per-dispatch approval {pa.name} spec_digest does not match the current spec; "
                f"refuse.", 17)
        if pa_obj.get("instance_id") != pa_inst["instance_id"]:
            die(f"per-dispatch approval {pa.name} is not bound to this instance "
                f"({pa_inst['instance_id'][:12]}…); refuse.", 17)
        if pa_obj.get("attempt") != n:
            die(f"per-dispatch approval {pa.name} attempt={pa_obj.get('attempt')} != launching "
                f"attempt {n}; refuse.", 17)
        if pa_obj.get("spec_id") != spec_id:
            die(f"per-dispatch approval {pa.name} spec_id={pa_obj.get('spec_id')!r} != launching "
                f"spec {spec_id!r}; refuse.", 17)
        if pa_obj.get("risk_class") != risk:
            die(f"per-dispatch approval {pa.name} risk_class={pa_obj.get('risk_class')!r} != spec "
                f"risk_class {risk!r}; refuse.", 17)

    if k == 0:
        return None  # initial attempt (or only infrastructure re-launches so far)

    limit = REMEDIATION_LIMITS.get(risk, REMEDIATION_LIMITS["default"])
    if k > limit:
        ev = {"merit_failures": [{"attempt": a, "status": r.get("status")} for a, r in fails],
              "limit": limit, "risk_class": risk}
        path = escalate(spec_id, f"remediation limit exhausted ({k} merit failures > "
                                 f"{limit} allowed remediations)", ev)
        write_state(spec_id, {"attempt_id": f"{spec_id}-{n}", "spec_id": spec_id, "attempt": n,
                              "spec_digest": digest, "status": "failed_remediation_exhausted",
                              "error_class": ERR_REMEDIATION, "escalation": str(path)})
        die(f"remediation limit exhausted for {spec_id} ({k} merit failures, limit {limit}); "
            f"spec FAILED and escalated: {path}", 18)

    last_n, last_r = fails[-1]
    last_f = findings_of(spec_id, last_n, last_r)
    if k >= 2:
        prev_f = findings_of(spec_id, fails[-2][0], fails[-2][1])
        if _findings_key(prev_f) == _findings_key(last_f):
            ev = {"identical_findings": last_f,
                  "attempts": [fails[-2][0], last_n], "risk_class": risk}
            path = escalate(spec_id, "stop-early: two consecutive attempts produced identical "
                                     "findings with no material change", ev)
            write_state(spec_id, {"attempt_id": f"{spec_id}-{n}", "spec_id": spec_id,
                                  "attempt": n, "spec_digest": digest,
                                  "status": "failed_remediation_exhausted",
                                  "error_class": ERR_REMEDIATION, "escalation": str(path)})
            die(f"stop-early for {spec_id}: attempts {fails[-2][0]} and {last_n} produced "
                f"identical findings; spec FAILED and escalated: {path}", 18)

    return {"remediation_number": k, "of_attempt": last_n, "findings": last_f,
            "limit": limit}


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


# ----------------------------------------------------- D5 worker isolation ----
# The worker AND the gate test run worker-produced code. Run both as a dedicated `codex-worker`
# UID in hardened transient SYSTEM services so FILESYSTEM PERMISSIONS separate them from the operator's
# credentials (risk 13-B: this host's Landlock backend can't restrict reads, so DAC is the boundary,
# not Codex's sandbox). Setup: scripts/setup-worker-user.sh. Proven by tests/worker_isolation.sh.
def _resolve_operator() -> "tuple[str, Path]":
    """The human operator this instance runs as (the box owner on the origin, anyone on a clone).
    Resolved from the passwd database (NSS) — NOT $HOME, which is unreliable under systemd/sudo
    (SOL). Override with ORCH_OPERATOR_USER. Never dies at import (tests import this module); strict
    validation happens where it matters."""
    import pwd
    name = os.environ.get("ORCH_OPERATOR_USER")
    if not name:
        try:
            name = pwd.getpwuid(os.getuid()).pw_name
        except Exception:
            name = "operator"
    try:
        home = Path(pwd.getpwnam(name).pw_dir)
    except Exception:
        home = Path(os.environ.get("HOME") or f"/home/{name}")
    return name, home


def execution_identity() -> str:
    import pwd
    try:
        return pwd.getpwuid(os.geteuid()).pw_name
    except KeyError:
        return str(os.geteuid())


OPERATOR_USER, OPERATOR_HOME = _resolve_operator()

WORKER_USER = "codex-worker"
WORKER_HOME = Path("/home/codex-worker")
ISO_WORKTREES = Path("/srv/codexwork/worktrees")
CODEX_PKG = OPERATOR_HOME / ".local/lib/node_modules/@openai/codex"  # npm layout; bind-mounted RO to /opt/codex


def _group_is_private(gid: int) -> bool:
    """True iff gid is the operator's PRIMARY group AND nobody but the operator belongs to it.
    Ubuntu's user-private-group scheme (umask 002) makes npm-installed files 664 with exactly
    such a group; anything looser fails. Membership is checked from BOTH sides (round-4 review):
    gr_mem lists supplementary members, but a user whose PRIMARY gid is this group never appears
    there — so passwd is also scanned. The worker must not be a member either way."""
    import grp
    import pwd
    try:
        g = grp.getgrgid(gid)
        op = pwd.getpwuid(os.getuid())
    except KeyError:
        return False
    if gid != op.pw_gid or any(m != op.pw_name for m in g.gr_mem):
        return False
    try:
        for u in pwd.getpwall():   # users whose PRIMARY group is this gid (absent from gr_mem)
            if u.pw_gid == gid and u.pw_name != op.pw_name:
                return False
    except OSError:
        return False
    try:
        if pwd.getpwnam(WORKER_USER).pw_gid == gid:
            return False
    except KeyError:
        pass
    return True


def _has_extended_acl(p: Path) -> bool:
    """True if p carries a named POSIX ACL (a `user:NAME:` / `group:NAME:` entry beyond the base
    owner/group/other). Such an entry can grant another principal write while leaving uid:gid:mode
    unchanged — invisible to a mode check, and it turns the mode's group bits into an ACL MASK
    (round-4 review). An entry that cannot be read is treated as extended (fail closed)."""
    try:
        return "system.posix_acl_access" in os.listxattr(p, follow_symlinks=False)
    except OSError as e:
        import errno
        # xattrs unsupported / none present -> no named ACL; anything else -> untrusted
        return e.errno not in (errno.ENOTSUP, errno.ENODATA)


def _trusted_ancestry(start: Path) -> bool:
    """Walk from `start` (a mount source's PARENT, already fully resolved — no symlinks) up to '/'.
    Each directory must be owned by root/operator and un-plantable, or a principal who controls it
    could rename/replace the source after the checks and before systemd mounts it (round-4 review:
    the pathname controller, not just the target). World/group-writable is tolerated ONLY with the
    sticky bit set — sticky stops non-owners renaming or deleting entries they do not own (this is
    what makes /tmp and some /home layouts safe ancestors). No named ACL. The mount source itself
    and its contents are checked STRICTLY elsewhere (sticky does not stop ADDING files, so it is
    not sufficient for the source dir)."""
    cur = start
    while True:
        try:
            st = cur.lstat()
        except OSError:
            return False
        if st.st_uid not in (0, os.getuid()):
            return False
        sticky = bool(st.st_mode & 0o1000)
        if (st.st_mode & 0o002) and not sticky:
            return False
        if (st.st_mode & 0o020) and not sticky and not _group_is_private(st.st_gid):
            return False
        if _has_extended_acl(cur):
            return False
        if cur == cur.parent:   # reached /
            return True
        cur = cur.parent


def _trusted_runtime_file(p: Path, want_exec: bool = True) -> Path | None:
    """Vet a file root will bind-mount into the worker service: resolve symlinks, then require a
    regular file owned by root or the operator, not world-writable, and group-writable ONLY when
    that group is verifiably private to the operator (_group_is_private — round-2 review: on a box
    where the operator's primary group has other members, "group-writable is fine" is an
    unenforced assumption, so it is enforced here). Executable when it will be exec'd directly.
    Returns the resolved real path, or None."""
    import stat as stat_m
    try:
        real = p.resolve(strict=True)
        st = real.stat()
    except OSError:
        return None
    if not stat_m.S_ISREG(st.st_mode) or (st.st_mode & 0o002):
        return None
    if (st.st_mode & 0o020) and not _group_is_private(st.st_gid):
        return None
    if st.st_uid not in (0, os.getuid()):
        return None
    if _has_extended_acl(real) or not _trusted_ancestry(real.parent):
        return None
    if want_exec and not os.access(real, os.X_OK):
        return None
    return real


def trusted_runtime_tree(root: Path) -> bool:
    """Every byte of a bind-mounted DIRECTORY is executed inside the worker service, so the whole
    tree — not just the entry file — must be un-plantable by the worker or any non-trust principal
    (round-3 review: npm mode mounts the package dir, whose launcher runs a separate vendor binary
    from inside the mount; trust-checking only node+entry left that binary swappable). Require of
    every entry: owned by root or the operator; not world-writable; group-writable only when the
    group is operator-private; and NO symlink whose resolved target escapes the tree (an external
    target can change without moving the tree fingerprint). The root dir itself is checked too."""
    import stat as stat_m
    try:
        real_root = root.resolve(strict=True)
    except OSError:
        return False
    if not _trusted_ancestry(real_root.parent):   # a plantable PARENT dir defeats the whole tree
        return False
    for p in [real_root, *real_root.rglob("*")]:
        try:
            st = p.lstat()
        except OSError:
            return False
        if st.st_uid not in (0, os.getuid()):
            return False
        if st.st_mode & 0o002:
            return False
        if (st.st_mode & 0o020) and not _group_is_private(st.st_gid):
            return False
        if _has_extended_acl(p):   # a named ACL grants write invisibly to a mode check
            return False
        if stat_m.S_ISLNK(st.st_mode):
            try:
                tgt = p.resolve(strict=True)
                tgt.relative_to(real_root)   # ValueError if it escapes the mounted tree
            except (OSError, ValueError):
                return False
    return True


def worker_codex_runtime():
    """How an ISOLATED worker runs Codex: (argv prefix, read-only bind mounts, entry file), or
    None when this box has no worker-launchable install. The worker cannot read the operator's
    home (that IS the boundary), so root bind-mounts the runtime past it. Two layouts are
    launchable: the npm package (needs a system node — the worker cannot reach ~/.local), or a
    native single ELF binary. Candidates are vetted (_trusted_runtime_file, and the WHOLE mounted
    tree via trusted_runtime_tree for npm) and fingerprinted at launch so _run refuses a runtime
    that changed under it. None must refuse at launch: the old npm-only assumption died opaquely
    in namespace setup on a native-install box, identically on every retry (dev-box feedback,
    R51)."""
    node = _trusted_runtime_file(Path("/usr/bin/node"))
    entry = _trusted_runtime_file(CODEX_PKG / "bin/codex.js", want_exec=False)
    if node and entry and trusted_runtime_tree(CODEX_PKG):
        # Bind and exec the RESOLVED real paths, never the unresolved strings (round-5 review): a
        # symlink component the checks followed could be repointed before systemd resolves the
        # bind source. `node` and the package root below are both already symlink-resolved.
        return ([str(node), "/opt/codex/bin/codex.js"],
                [(str(CODEX_PKG.resolve()), "/opt/codex")], entry)
    import shutil
    cands = [OPERATOR_HOME / ".codex/bin/codex", OPERATOR_HOME / ".local/bin/codex",
             Path("/usr/local/bin/codex"), Path("/usr/bin/codex")]
    which = shutil.which("codex")
    if which:
        cands.append(Path(which))
    for cand in cands:
        real = _trusted_runtime_file(cand)
        if real is None:
            continue
        try:
            with real.open("rb") as fh:
                elf = fh.read(4) == b"\x7fELF"
        except OSError:
            continue
        if elf:  # an npm shim here would still need node; only a real binary is self-sufficient
            return ["/opt/codex/codex"], [(str(real), "/opt/codex/codex")], real
    return None


def worker_kimi_runtime():
    """How an ISOLATED worker runs kimi: (argv prefix, read-only bind mounts, entry file), or
    None when this box has no worker-launchable install. Native single-ELF ONLY (probe A,
    .orchestrator/evidence/kimi-probes.md: kimi-code ships as one static binary; no npm layout
    exists). Candidates are vetted by _trusted_runtime_file, ELF-checked, and fingerprinted at
    launch so _run refuses a runtime that changed under it; the resolved real binary is
    bind-mounted past the operator-home boundary to /opt/kimi/kimi."""
    import shutil
    cands = [OPERATOR_HOME / ".kimi-code/bin/kimi", OPERATOR_HOME / ".local/bin/kimi",
             Path("/usr/local/bin/kimi"), Path("/usr/bin/kimi")]
    which = shutil.which("kimi")
    if which:
        cands.append(Path(which))
    for cand in cands:
        real = _trusted_runtime_file(cand)
        if real is None:
            continue
        try:
            with real.open("rb") as fh:
                elf = fh.read(4) == b"\x7fELF"
        except OSError:
            continue
        if elf:
            return ["/opt/kimi/kimi"], [(str(real), "/opt/kimi/kimi")], real
    return None


def worker_runtime_resolver(vendor):
    """The module-level runtime resolver for a frozen worker vendor — selection follows the
    FROZEN vendor at launch and in the legacy fallback (kimi brief, slice 3). Runtime
    resolution and vetting are trust machinery and stay in this module; adapters only
    delegate. Every external-CLI vendor without its own resolver is codex today."""
    return worker_kimi_runtime if vendor == "kimi" else worker_codex_runtime


def runtime_fingerprint(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _tree_fingerprint(root: Path) -> str:
    """Deterministic hash of a whole directory tree (names, modes, symlink targets, contents).
    The npm layout bind-mounts the PACKAGE DIRECTORY, whose launcher executes a separate vendor
    binary from inside the mount — hashing only the entry file left every other mounted byte
    unpinned (round-2 review). Special files taint the hash by type+name."""
    import stat as stat_m
    h = hashlib.sha256()
    for p in sorted(root.rglob("*")):
        rel = str(p.relative_to(root)).encode()
        st = p.lstat()
        # Owner/group/mode are part of the identity (round-3 review): a mode or ownership flip that
        # opens a file to another principal must move the hash even when the bytes are unchanged.
        meta = f"{st.st_uid}:{st.st_gid}:{oct(st.st_mode)}:".encode()
        if stat_m.S_ISLNK(st.st_mode):
            h.update(b"L" + rel + meta + os.readlink(p).encode())
        elif stat_m.S_ISREG(st.st_mode):
            h.update(b"F" + rel + meta)
            with p.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
        elif stat_m.S_ISDIR(st.st_mode):
            h.update(b"D" + rel + meta)
        else:
            h.update(b"X" + rel + meta)
    return h.hexdigest()


def pin_runtime_sources(rt_argv: list, rt_binds: list) -> dict:
    """path -> fingerprint for EVERYTHING the worker service will execute: every bind-mount
    source (file or whole tree) plus the host-side interpreter when argv[0] is not itself under a
    pinned mount (npm mode runs /usr/bin/node from the host /usr). _run recomputes these
    immediately before starting the service; the residual hash->mount window is milliseconds and
    writable only by operator/root — the box's trust root — which content re-hashing at use time
    covers at least as well as device/inode pinning would."""
    pins = {}
    for src, _dst in rt_binds:
        sp = Path(src)
        pins[src] = _tree_fingerprint(sp) if sp.is_dir() else runtime_fingerprint(sp)
    # argv[0] is host-pinned only when it executes FROM the host (npm's /usr/bin/node); a bind
    # DESTINATION is not a host path — its source is already pinned above. Recognizing any
    # destination (was: a literal /opt/codex prefix — kimi slice 3) keeps codex npm/native
    # behavior identical and lets another vendor's mount (kimi's /opt/kimi/kimi) pin without
    # probing a nonexistent host path. Round-1 review (high): a degenerate destination (""
    # or "/") would cover EVERY absolute argv[0] and silently drop the host pin — only a
    # proper absolute destination below / is recognized; anything else keeps the
    # conservative host pin (fail closed).
    def _covered(a0, dst):
        dst = dst.rstrip("/")
        return dst.startswith("/") and bool(dst.strip("/")) and (
            a0 == dst or a0.startswith(dst + "/"))
    if not any(_covered(rt_argv[0], dst) for _src, dst in rt_binds):
        pins[rt_argv[0]] = runtime_fingerprint(Path(rt_argv[0]))
    return pins


def trusted_test_runtime() -> dict | None:
    """Return the root-owned Python dependency closure used by installed tests, or None.

    Unlike the Codex runtime, operator ownership is not accepted: candidate-phase provenance says
    this runtime is trusted specifically because setup installed it root-owned outside the
    operator's home and the worker cannot modify any byte or path component.
    """
    import stat as stat_m
    try:
        real = TEST_RUNTIME_ROOT.resolve(strict=True)
        interpreter = TEST_RUNTIME_PY.resolve(strict=True)
    except OSError:
        return None
    if real != TEST_RUNTIME_ROOT:
        return None
    for ancestor in (Path("/"), Path("/opt"), TEST_RUNTIME_ROOT):
        try:
            st = ancestor.lstat()
        except OSError:
            return None
        if st.st_uid != 0 or st.st_mode & 0o022 or _has_extended_acl(ancestor):
            return None
    for p in [real, *real.rglob("*")]:
        try:
            st = p.lstat()
        except OSError:
            return None
        if st.st_uid != 0 or _has_extended_acl(p):
            return None
        if stat_m.S_ISLNK(st.st_mode):
            try:
                target = p.resolve(strict=True)
            except OSError:
                return None
            try:
                target.relative_to(real)
            except ValueError:
                if _trusted_runtime_file(target, want_exec=False) is None or target.stat().st_uid != 0:
                    return None
            continue
        if st.st_mode & 0o022:
            return None
        if not (stat_m.S_ISREG(st.st_mode) or stat_m.S_ISDIR(st.st_mode)):
            return None
    if not TEST_RUNTIME_PY.exists() or not os.access(TEST_RUNTIME_PY, os.X_OK):
        return None
    trusted_interpreter = _trusted_runtime_file(interpreter)
    if trusted_interpreter is None or trusted_interpreter.stat().st_uid != 0:
        return None
    requirements_sha = sha256_file(ROOT / "scripts" / "requirements.txt")
    try:
        installed_requirements_sha = (TEST_RUNTIME_ROOT / ".requirements-sha256").read_text().strip()
    except OSError:
        return None
    if installed_requirements_sha != requirements_sha:
        return None
    return {"python": str(TEST_RUNTIME_PY), "root": str(TEST_RUNTIME_ROOT),
            "tree_sha256": _tree_fingerprint(TEST_RUNTIME_ROOT),
            "interpreter": str(trusted_interpreter),
            "interpreter_sha256": runtime_fingerprint(trusted_interpreter),
            "requirements_sha256": requirements_sha}


def test_runtime_matches(record: dict | None) -> bool:
    current = trusted_test_runtime()
    return bool(record and current and current == record)


def isolation_available() -> bool:
    """D5 is ON iff the dedicated user + shared worktree root exist and we can sudo non-interactively.
    OFF (fresh box / CI) falls back to same-user launch so the dispatcher still runs — but a launch
    then records isolation:false so the provenance never overstates the boundary."""
    try:
        import pwd
        pwd.getpwnam(WORKER_USER)
    except Exception:
        return False
    return ISO_WORKTREES.exists() and run(["sudo", "-n", "true"]).returncode == 0


def worktree_root(iso: bool | None = None) -> Path:
    """T2: pass the FROZEN launch decision. The default recomputes only for read-only callers
    (reconcile/health); the launch path must always pass its decision explicitly."""
    if iso is None:
        iso = isolation_available()
    return ISO_WORKTREES if iso else WORKTREES


def grant_worker_acl(wt: Path) -> None:
    """Let codex-worker read/write the worktree and the operator read worker-created files (independent of
    the operator's session groups). Deny the worker the .git pointer (belt; its target is in the operator's home)."""
    run(["setfacl", "-R", "-m", f"u:{WORKER_USER}:rwX", "-m", f"u:{OPERATOR_USER}:rwX", str(wt)])
    run(["setfacl", "-R", "-d", "-m", f"u:{WORKER_USER}:rwX", "-d", "-m", f"u:{OPERATOR_USER}:rwX",
         str(wt)])
    if (wt / ".git").exists():
        run(["setfacl", "-x", f"u:{WORKER_USER}", str(wt / ".git")])


def attempt_slice(attempt_id: str) -> str:
    """B6: every SYSTEM unit isolated_run spawns for one attempt (worker, test, each installed-test,
    both regression runs) shares this one slice, so a single stop tears down all of them regardless
    of how many suffixed units exist. It is a SYSTEM slice (these are `sudo systemd-run` units, not
    --user) — the outer --user pipeline unit cannot join it (a system-manager slice cannot contain a
    user-manager unit) and is stopped separately."""
    return f"codex-{attempt_id}.slice"


MIN_PHASE_CEILING_S = 30  # B6: a phase needs at least this many seconds LEFT to the absolute deadline
                          # to start; with fewer, the phase is REFUSED (return 0) — never granted the
                          # floor, which would let a child outlive the one hard deadline.


def remaining_ceiling_s(deadline_ts: float) -> int:
    """Seconds left to the ONE absolute attempt deadline recorded at launch (B6). Every phase spends
    down this SAME deadline — never a fresh full ceiling — so total wall-clock cannot exceed the
    configured hard ceiling. Returns 0 (the caller MUST refuse to start the phase) whenever fewer
    than MIN_PHASE_CEILING_S remain: the floor is a REFUSAL threshold, not a grant floor, so a child
    is never handed more time than actually remains to the absolute deadline (round-1 review, B6)."""
    remaining = int(deadline_ts - time.time())
    if remaining < MIN_PHASE_CEILING_S:
        return 0
    return remaining


def deadline_timeout_prefix(deadline_ts: float) -> "list[str] | None":
    """coreutils `timeout` prefix (round-2 review, finding 3) that hard-caps a phase WITHOUT its own
    systemd RuntimeMaxSec — the unisolated worker / spec-test / regression runs, the candidate-read
    grader, and the reviewer LLM call — at the wall-clock time REMAINING to the ONE absolute deadline.
    A pre-start check alone let a phase, once started, run arbitrarily far past the deadline; this
    binds the whole phase to it. `-k 10` escalates TERM->KILL 10s later so a phase that ignores TERM
    still cannot outlive the cap. Returns None when no time remains — the caller MUST refuse the
    phase, exactly like remaining_ceiling_s()==0 for the systemd-capped phases."""
    remaining = remaining_ceiling_s(deadline_ts)
    if remaining <= 0:
        return None
    return ["timeout", "-k", "10", str(remaining)]


# Deferred (B6 residual, follow-ups to BACKLOG item 6 / the audit residual list; review cap spent):
#  - GRACE WINDOW: `timeout -k 10` and systemd RuntimeMaxSec/TimeoutStopSec send SIGTERM first and
#    SIGKILL only after a grace interval, so a phase can run a few seconds PAST deadline_ts before it
#    is force-killed. Tightening to a hard immediate kill (e.g. `timeout -s KILL`, TimeoutStopSec=0)
#    is deferred — the grace exists on purpose to let a phase flush evidence/logs before dying.
#  - PRE-DEADLINE OPS: deadline_ts is established in cmd_launch AFTER the box-precondition drills and
#    the pre-outer worktree/base setup, so a hang in THOSE steps is outside the absolute ceiling.
#    Moving deadline establishment earlier (before preconditions) is deferred; those steps run as the
#    operator, are not worker-controlled, and have their own narrower guards.


def isolated_cmd(unit, argv, cwd, rw_paths, private_network, ceiling_s,
                 binds=None, env_extra=None, slice_name=None):
    """Build the exact hardened systemd-run command isolated_run executes. Exposed so the kimi
    ACP transport (scripts/kimi_acp.py) can drive the IDENTICAL envelope with its own stdio
    pipes instead of isolated_run's devnull/file handles — a change here changes both paths."""
    # NOTE: no ProtectHome — it would tmpfs-hide the worker's OWN CODEX_HOME (auth). the operator's home is
    # blocked explicitly by InaccessiblePaths + DAC; the worker's own home stays accessible.
    props = ["--property=ProtectSystem=strict",
             f"--property=InaccessiblePaths={OPERATOR_HOME}", "--property=PrivateTmp=yes",
             "--property=NoNewPrivileges=yes", "--property=RestrictSUIDSGID=yes",
             "--property=UMask=0007", f"--property=RuntimeMaxSec={ceiling_s}"]
    if slice_name:
        props.append(f"--slice={slice_name}")
    for p in rw_paths:
        props.append(f"--property=ReadWritePaths={p}")
    for src, dst in (binds or []):
        props.append(f"--property=BindReadOnlyPaths={src}:{dst}")
    if private_network:
        props.append("--property=PrivateNetwork=yes")
    if cwd:
        props.append(f"--property=WorkingDirectory={cwd}")
    # GIT_NO_REPLACE_OBJECTS (round-3): detached grader worktrees share the object store AND its
    # refs/replace, so a grader's OWN in-process `git` object reads would still resolve replacement
    # objects unless the child's environment disables them. Export it into every hardened grader
    # unit (candidate-isolated + regression phases + the spec test_command all route through here).
    # R73 Job 2 rounds 1+2: the worker's vendor auth/state variables are adapter surface — the
    # worker call site supplies them via env_extra (worker_adapter.iso_env_extra), which
    # OVERRIDES this base by dict merge, so a Job 3 vendor injects its own without touching
    # other units. CODEX_HOME itself STAYS in the base env (round-2 review): every isolated
    # unit — runtime probes, spec test_command, regression and integration graders — carried it
    # before Job 2, and a test_command reading $CODEX_HOME must not change terminal status
    # under a behavior-identical refactor. Retiring the legacy base variable is Job 3 work,
    # reviewable together with the non-worker units' environment contract.
    envs = {"HOME": str(WORKER_HOME), "PATH": "/usr/bin:/bin",
            "CODEX_HOME": str(WORKER_HOME / ".codex"), "TERM": "dumb", "LANG": "C.UTF-8",
            "GIT_NO_REPLACE_OBJECTS": "1", **(env_extra or {})}
    setenvs = [f"--setenv={k}={v}" for k, v in envs.items()]
    return ["sudo", "-n", "systemd-run", f"--uid={WORKER_USER}", f"--gid={WORKER_USER}",
            "--pipe", "--wait", "--quiet", "--collect", f"--unit={unit}", *props, *setenvs,
            "--", *argv]


def isolated_run(unit, argv, cwd, rw_paths, private_network, ceiling_s, stdout, stderr,
                 binds=None, env_extra=None, slice_name=None):
    """Run argv as codex-worker in a hardened transient SYSTEM service; block for completion.
    Writes are confined to rw_paths; the operator's home is inaccessible; the gate test passes
    private_network=True (untrusted code, no API needed). The service is a system unit (own cgroup,
    own RuntimeMaxSec) — store `unit` so cancel/health can stop it independently of the outer unit.
    slice_name (B6) places this unit in the attempt's shared slice (attempt_slice()) so cancel/health/
    reconcile can tear down every unit family for the attempt with one `systemctl stop <slice>`."""
    cmd = isolated_cmd(unit, argv, cwd, rw_paths, private_network, ceiling_s,
                       binds=binds, env_extra=env_extra, slice_name=slice_name)
    with open(os.devnull) as devnull:
        return subprocess.run(cmd, stdin=devnull, stdout=stdout, stderr=stderr)


def validate_worktree_safe(wt: Path) -> list[str]:
    """Before the orchestrator (the operator) touches worker output: reject unsafe filesystem entries a
    hostile patch could plant — symlinks, FIFOs, sockets, devices — so no later operator-context step
    follows a link into the operator's files. Skips .git. Returns a list of offending repo-relative paths."""
    bad = []
    for p in wt.rglob("*"):
        rel = p.relative_to(wt)
        if rel.parts and rel.parts[0] == ".git":
            continue
        try:
            st = p.lstat()
        except OSError:
            continue
        import stat as _stat
        m = st.st_mode
        if _stat.S_ISLNK(m) or _stat.S_ISFIFO(m) or _stat.S_ISSOCK(m) \
                or _stat.S_ISBLK(m) or _stat.S_ISCHR(m):
            bad.append(str(rel))
    return bad


def run_regression_gate(lc, wt, worker_commit, att, iso, deadline_ts) -> dict:
    """Prove the change's new test actually CATCHES the intended defect (holistic-review #1, SOL).

    A test that passes on the candidate proves nothing about whether it would have failed on the bug
    it claims to fix. So: run the human-authored `regression_command` against a throwaway worktree at
    the base commit with the candidate's `regression_test_paths` overlaid — it MUST fail there (the
    fix is absent) — and against the candidate — it MUST pass. Overlaying the test files is what makes
    the base failure meaningful: it fails because the assertion is unmet, not because the test file is
    missing. Runs worker-authored code → isolated exactly like the test phase (network off).
    Returns a result dict; result=="PASS" iff base FAILS and candidate PASSES.

    deadline_ts (B6) is the ONE absolute attempt deadline; each of the two runs below gets only the
    time remaining to it, not a fresh full ceiling, and both share the attempt's systemd slice so
    cancel/health/reconcile tear them down with everything else.

    DEFERRED (B4 round-3, BACKLOG item 6 / SECURITY.md gap 3): unlike the box/candidate-read/
    integration graders, this gate still executes the human-authored `regression_command` from the
    MUTABLE candidate (`wt`) and base worktrees, and does not hash those bytes against the pinned
    commit. Full materialization of the regression path (a pinned base checkout + pinned candidate
    blobs) is a larger refactor scoped as follow-up; we do the cheap hardening here — export
    GIT_NO_REPLACE_OBJECTS into the subprocess env so a planted refs/replace can't alter the
    command's own git object reads either — but the same-class working-tree read remains open."""
    cmd = lc["regression_command"]
    paths = lc.get("regression_test_paths", [])
    base_sha = lc["base_sha"]
    attempt_id = lc["attempt_id"]
    base_wt = worktree_root() / f"{attempt_id}-regbase"
    res = {"command": cmd, "test_paths": paths, "base_sha": base_sha,
           "worker_commit": worker_commit, "isolation": iso,
           "base_exit": None, "candidate_exit": None, "result": "FAIL", "reason": ""}

    def _run_in(unit, cwd, log_path, phase_ceiling_s):
        if iso:
            with open(log_path, "w") as lg:
                cp = isolated_run(unit, ["bash", "-c", cmd], cwd=str(cwd),
                                  rw_paths=[str(cwd)], private_network=True,
                                  ceiling_s=phase_ceiling_s, stdout=lg, stderr=subprocess.STDOUT,
                                  slice_name=attempt_slice(attempt_id))
            return cp.returncode
        # Unisolated fallback: no systemd RuntimeMaxSec, so cap the run itself at the remaining time
        # to the absolute deadline (B6), not just a pre-start check; and export GIT_NO_REPLACE_OBJECTS
        # (B4) so a planted refs/replace can't alter the command's own git object reads.
        cp = run(["timeout", "-k", "10", str(phase_ceiling_s), "bash", "-c", cmd], cwd=str(cwd),
                 env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"})
        Path(log_path).write_text((cp.stdout or "") + (cp.stderr or ""))
        return cp.returncode

    if base_wt.exists():
        run(["git", "worktree", "remove", "--force", str(base_wt)])
    try:
        git("worktree", "add", "--quiet", "--detach", str(base_wt), base_sha)
        # Overlay the candidate's test files onto the base so the base run fails for the RIGHT reason.
        try:
            git("checkout", worker_commit, "--", *paths, cwd=base_wt)
        except SystemExit:
            res["reason"] = (f"could not overlay regression_test_paths {paths} from the candidate onto "
                             f"the base — check the paths exist in the change.")
            return res
        if iso:
            grant_worker_acl(base_wt)
        base_ceiling_s = remaining_ceiling_s(deadline_ts)
        if base_ceiling_s <= 0:
            res["reason"] = ("attempt deadline exhausted before the regression gate's base run could "
                             "start (single absolute ceiling, B6); refusing")
            return res
        res["base_exit"] = _run_in(f"codex-regbase-{attempt_id}", base_wt,
                                   att / "regression-base.log", base_ceiling_s)
        cand_ceiling_s = remaining_ceiling_s(deadline_ts)
        if cand_ceiling_s <= 0:
            res["reason"] = ("attempt deadline exhausted before the regression gate's candidate run "
                             "could start (single absolute ceiling, B6); refusing")
            return res
        res["candidate_exit"] = _run_in(f"codex-regcand-{attempt_id}", wt,
                                        att / "regression-candidate.log", cand_ceiling_s)
    finally:
        if base_wt.exists():
            run(["git", "worktree", "remove", "--force", str(base_wt)])

    if res["base_exit"] == 0:
        res["reason"] = ("vacuous regression proof: regression_command PASSED on the base — the test "
                         "does not catch the intended defect (it would have passed before the fix).")
    elif res["candidate_exit"] != 0:
        res["reason"] = (f"regression_command FAILED on the candidate (exit {res['candidate_exit']}) — "
                         f"the change does not satisfy its own regression test.")
    else:
        res["result"] = "PASS"
        res["reason"] = ("fails on base, passes on candidate — the new test provably catches the "
                         "intended defect.")
    return res


def _status_for_exit(rc: int) -> str:
    return "PASS" if rc == 0 else ("SKIP" if rc == 77 else "FAIL")


def attestation_record(policy: dict, observations: dict[str, list[dict]]) -> dict:
    ok, detail = attest_tests(observations, policy["required"], policy["modes"], policy)
    tests = {}
    for rel in policy["required"]:
        tests[rel] = {"assigned_phase": policy["modes"][rel],
                      "observations": observations.get(rel, [])}
    return {"policy": policy, "required": policy["required"], "tests": tests,
            "attested": ok, "detail": detail}


def run_box_preconditions(att: Path, policy: dict) -> dict[str, list[dict]]:
    """Run installed box drills as the operator, serialized, before candidate worktree creation.

    Box-precondition tests inspect the REAL host (bwrap/AppArmor/ACL state) as the operator and
    self-locate via `cd "$(dirname "$0")/.."`. Findings 1+2 (round 2): they are executed and hashed
    from an IMMUTABLE grader tree checked out OUTSIDE the repo working tree — never a path under the
    working tree an operator-context process could rename/swap during the run. dirname("$0")/..
    resolves the grader tree, and their data dependencies (e.g. scripts/dispatch.py) are the pinned
    commit's. The executed file is hashed before/after and checked against policy["test_sha256"][rel]
    downstream in attest_tests(), so a tamper of the grader tree itself still fails closed."""
    observations: dict[str, list[dict]] = {rel: [] for rel in policy["required"]}
    box_tests = [rel for rel in policy["required"]
                 if policy["modes"][rel] == "box-precondition"]
    lock = STATE / ".box-preconditions.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    installed_commit = policy["installed_commit"]
    host_id = Path("/etc/machine-id").read_text().strip() if Path("/etc/machine-id").exists() else "unknown"
    boot_id = (Path("/proc/sys/kernel/random/boot_id").read_text().strip()
               if Path("/proc/sys/kernel/random/boot_id").exists() else "unknown")
    # The grader tree never contains the untracked .venv, so interpreter-needing drills
    # (codex_runtime.sh) must get the root-owned runtime explicitly; absent runtime -> unset,
    # and the drill's own SKIP fails the gate closed exactly as before.
    test_rt = trusted_test_runtime()
    with open(lock, "w") as lf, materialized_grader_tree(installed_commit, ROOT) as gtree:
        fcntl.flock(lf, fcntl.LOCK_EX)
        for rel in box_tests:
            before_commit = git("rev-parse", "HEAD", cwd=ROOT)
            before_manifest = hashlib.sha256(git_show_bytes(
                installed_commit, "tests/execution-policy.tsv", cwd=ROOT)).hexdigest()
            started = now()
            log = att / "raw" / f"box-precondition-{Path(rel).stem}.log"
            env = {"HOME": str(OPERATOR_HOME), "USER": OPERATOR_USER,
                   "LOGNAME": OPERATOR_USER, "PATH": "/usr/local/bin:/usr/bin:/bin",
                   "LANG": "C.UTF-8", "ORCH_OPERATOR_USER": OPERATOR_USER,
                   # round-3: the grader worktree shares refs/replace; disable it for the box
                   # drill's own git object reads too (it reads scripts/dispatch.py etc.).
                   "GIT_NO_REPLACE_OBJECTS": "1",
                   **({"ORCH_TEST_PY": test_rt["python"]} if test_rt else {})}
            run_path = _grader_run_path(gtree, rel)
            before_test = sha256_file(run_path)
            with open(log, "w") as out:
                cp = subprocess.run(["bash", str(run_path)], cwd=str(gtree), env=env,
                                    stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=subprocess.STDOUT)
            after_test = sha256_file(run_path)   # the bytes we actually executed
            after_manifest = sha256_file(gtree / "tests" / "execution-policy.tsv")
            after_commit = git("rev-parse", "HEAD", cwd=ROOT)
            status = _status_for_exit(cp.returncode)
            actual_identity = execution_identity()
            if (before_test != after_test or before_manifest != after_manifest
                    or before_commit != installed_commit or after_commit != installed_commit
                    or actual_identity != OPERATOR_USER or host_id == "unknown" or boot_id == "unknown"):
                status = "FAIL"
            observations[rel].append({
                "phase": "box-precondition", "status": status,
                "subject": "active host and installed isolation boundary",
                "identity": actual_identity, "installed_commit": installed_commit,
                "installed_commit_after": after_commit,
                "host_id": host_id, "boot_id": boot_id,
                "serialization_lock": str(lock),
                "manifest_sha256": before_manifest, "test_sha256": before_test,
                "manifest_sha256_after": after_manifest, "test_sha256_after": after_test,
                "started": started, "finished": now(), "exit_status": cp.returncode,
                "log": str(log.relative_to(att)), "log_sha256": sha256_file(log),
                "claim": ("active installed box boundary passed; candidate test version was not graded"
                          if status == "PASS" else
                          "active installed box boundary did not pass; candidate launch is blocked"),
            })
            atomic_write(att / "test-attestation.json",
                         json.dumps(attestation_record(policy, observations), indent=2))
        fcntl.flock(lf, fcntl.LOCK_UN)
    return observations


# =============================================================== launch =======
def cmd_launch(spec_id: str) -> None:
    # T2 (decision R26) — ISOLATION FAILS CLOSED. Selected ONCE, FIRST — before preflight, the
    # slot claim, the attempt directory, the worktree, and any worker-controlled code. Everything
    # downstream is handed this decision; nothing recomputes it (a recomputation is a downgrade
    # path). First deliberately: a box that cannot isolate cannot launch ANY spec, so no other
    # error (missing spec, missing approval) may mask this refusal.
    #
    # The old behaviour silently fell back to running worker code as the operator whenever D5 was
    # unavailable — with the operator's credentials, home, and network. That is the one catastrophe
    # that is actually plausible on this box, and it was the DEFAULT on a fresh box or in CI.
    #
    # Break-glass is deliberately crude: an env var you type knowingly. No root secret, no
    # single-use token, no sudoers helper, no redemption ledger — that machinery defends a
    # single-tenant box from its own owner, and building it cost a day and shipped nothing.
    # R73 Job 3 (round-1 review, blocking 5): the gate covers BOTH exposure surfaces and says so.
    # External-CLI mode runs WORKER code isolated; EVERY mode runs candidate TEST code isolated
    # (the spec test executes worker-authored code). A subagent BUILD is deliberately operator-
    # context (SECURITY.md) and is NOT what this gate is about — on a D5-less box the refusal
    # protects the grading test phase, and break-glass accepts exactly that named exposure.
    iso = isolation_available()
    exposed = os.environ.get("ORCH_ALLOW_UNISOLATED") == "1"
    if not iso and not exposed:
        die("REFUSING to launch: isolation (D5) is unavailable.\n"
            "  Worker code (external-CLI mode) and candidate TEST code (every mode) would run\n"
            "  as YOU — your home, your credentials, your network.\n"
            "  Fix it:        ./scripts/setup-worker-user.sh\n"
            "  Or accept it:  ORCH_ALLOW_UNISOLATED=1 ./scripts/dispatch launch " + spec_id + "\n"
            "                 (that is FULL EXPOSURE, not a sandbox — it is recorded in the evidence)",
            ERR_NO_ISOLATION_RC)
    if not iso and exposed:
        print("!!! UNISOLATED: worker code (external-CLI mode) and candidate test code (every\n"
              "!!! mode) run as the operator with full access to this host, its credentials and\n"
              "!!! its network. You asked for this (ORCH_ALLOW_UNISOLATED=1).\n"
              "!!! It is recorded in launch.json and in the reviewer's evidence.", file=sys.stderr)

    # R73 Job 3: the frozen worker MODE decides which runtime this launch must probe, so spec,
    # approval, and model/vendor/mode resolution move ahead of the runtime checks (all read-only,
    # all refuse cleanly with no side effects; the isolation gate above deliberately stays first).
    ctx = preflight(spec_id)
    spec, digest, approval = ctx["spec"], ctx["digest"], ctx["approval"]
    # R71: role→model defaults come from scripts/models.json, read once here and frozen into lc
    # below. An approval that explicitly pins a model still wins (owner decision 2026-07-15).
    # Resolution (incl. pin revalidation) happens before the attempt claim, branch, or worktree
    # exist — an invalid pin refuses cleanly with no side effects (owner-extension round 1: a
    # late die() stranded a claimed 'launching' state).
    cfg = load_model_config()
    launch_models = resolve_launch_models(approval, cfg)
    subagent_mode = launch_models["worker_mode"] == "subagent"
    # Kimi slice 3: kimi has NO unisolated mode — the CLI cannot set its own working directory
    # and has no inner sandbox (codex's unisolated fallback keeps bwrap ON; kimi would run with
    # no confinement at all). The adapter refuses at argv build; refusing HERE keeps the
    # failure before the attempt is claimed and before any worktree or worker side effect
    # (preflight's instance bookkeeping is the only earlier write — round-1 review, medium 2).
    if not iso and launch_models["worker_vendor"] == "kimi":
        die("REFUSING to launch: kimi workers have no unisolated mode (no --cd, no inner "
            "sandbox — the hardened service is the only confinement). Provision isolation "
            "with ./scripts/setup-worker-user.sh, or choose another worker vendor.", 15)
    spec_bytes = ctx["spec_bytes"]   # the single buffer preflight read/hashed/parsed (B2 round-2)

    # Same fail-fast doctrine for the worker's Codex runtime: an isolated launch without one dies
    # in namespace setup AFTER the attempt is claimed — opaquely, identically on every retry.
    # Resolution is vetted, then PROBED under the real service hardening (an ELF-magic check alone
    # accepts wrong-arch/broken binaries — round-1 review), then pinned by hash for _run.
    # Subagent mode has NO worker CLI: it skips the worker-runtime probe (runtime_record stays
    # None) but keeps the trusted TEST runtime requirement — the grading half is unchanged.
    runtime_record = None
    test_runtime_record = None
    if iso and subagent_mode:
        test_runtime_record = trusted_test_runtime()
        if test_runtime_record is None:
            die("REFUSING to launch: trusted test runtime is missing or writable.\n"
                "  Run ./scripts/setup-worker-user.sh to provision the root-owned runtime at "
                f"{TEST_RUNTIME_ROOT}.", 15)
        probe = isolated_run(
            f"orch-test-rtprobe-{spec_id}",
            [test_runtime_record["python"], "-c", "import yaml, jsonschema"], cwd=None,
            rw_paths=[], private_network=True, ceiling_s=120,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            binds=[(test_runtime_record["root"], test_runtime_record["root"])],
            env_extra={"ORCH_TEST_PY": test_runtime_record["python"]})
        if probe.returncode != 0:
            die("REFUSING to launch: trusted test runtime failed under service hardening "
                f"(exit {probe.returncode}).", 15)
    elif iso:
        # Kimi slice 3: the resolver follows the FROZEN worker vendor (codex behavior, unit
        # name included, is byte-identical — the vendor is "codex" there).
        wv = launch_models["worker_vendor"]
        rt = worker_runtime_resolver(wv)()
        if rt is None and wv == "kimi":
            die("REFUSING to launch: no worker-launchable kimi runtime on this box.\n"
                "  Isolated kimi workers need a native kimi ELF binary (~/.kimi-code/bin,\n"
                "  ~/.local/bin, /usr/local/bin, /usr/bin, or on PATH) — owned by\n"
                "  root/operator, not group/world-writable. Install kimi-code natively,\n"
                "  then relaunch.", 15)
        if rt is None:
            die("REFUSING to launch: no worker-launchable Codex runtime on this box.\n"
                "  Isolated workers need EITHER the npm package\n"
                "  (~/.local/lib/node_modules/@openai/codex + a system node at /usr/bin/node)\n"
                "  OR a native codex ELF binary (~/.codex/bin, ~/.local/bin, /usr/local/bin,\n"
                "  /usr/bin, or on PATH) — owned by root/operator, not group/world-writable.\n"
                "  Fix: npm install -g --prefix ~/.local @openai/codex   (plus a system node),\n"
                "       or install the native binary. Then relaunch.", 15)
        rt_argv, rt_binds, rt_entry = rt
        probe = isolated_run(f"{wv}-rtprobe-{spec_id}", [*rt_argv, "--version"], cwd=None,
                             rw_paths=[], private_network=True, ceiling_s=120,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, binds=rt_binds)
        if probe.returncode != 0:
            # Round-1 review (medium 3): codex messages stay byte-identical — "Codex", not the
            # lowercase vendor token, on every pre-slice-3 path.
            rt_name = "Codex" if wv == "codex" else wv
            die(f"REFUSING to launch: the resolved {rt_name} runtime failed its probe under the real "
                f"service hardening (exit {probe.returncode}).\n"
                f"  Runtime: {rt_entry}\n"
                f"  Probe stderr: {(probe.stderr or b'').decode('utf-8', 'replace').strip()[-400:]}",
                15)
        runtime_record = {"argv": rt_argv, "binds": [list(b) for b in rt_binds],
                          "entry": str(rt_entry),
                          "pins": pin_runtime_sources(rt_argv, rt_binds)}
        test_runtime_record = trusted_test_runtime()
        if test_runtime_record is None:
            die("REFUSING to launch: trusted test runtime is missing or writable.\n"
                "  Run ./scripts/setup-worker-user.sh to provision the root-owned runtime at "
                f"{TEST_RUNTIME_ROOT}.", 15)
        probe = isolated_run(
            f"orch-test-rtprobe-{spec_id}",
            [test_runtime_record["python"], "-c", "import yaml, jsonschema"], cwd=None,
            rw_paths=[], private_network=True, ceiling_s=120,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            binds=[(test_runtime_record["root"], test_runtime_record["root"])],
            env_extra={"ORCH_TEST_PY": test_runtime_record["python"]})
        if probe.returncode != 0:
            die("REFUSING to launch: trusted test runtime failed under service hardening "
                f"(exit {probe.returncode}).", 15)

    try:
        installed_commit = git("rev-parse", "HEAD", cwd=ROOT)
        drift = grader_drift(installed_commit, ROOT)
        if drift:
            raise ValueError(
                "grader input (tests/, scripts/test) differs from the working tree at pinned "
                f"commit {installed_commit[:9]} — refusing to derive the required suite from an "
                "unpinned checkout: " + "; ".join(drift))
        policy = execution_policy(ROOT, installed_commit)
    except ValueError as e:
        die(f"REFUSING to launch: {e}", 15)

    n = next_attempt(spec_id)
    # Gate 4: remediation budget + stop-early + high-risk per-dispatch approval. Dies (recording
    # failed_remediation_exhausted + escalation) if this launch is not permitted.
    remediation = remediation_preflight(spec_id, spec, digest, n)
    attempt_id = f"{spec_id}-{n}"
    att_dir = ATTEMPTS / spec_id / str(n)
    (att_dir / "raw").mkdir(parents=True, exist_ok=True)
    # B2: freeze the exact approved spec bytes into the attempt now, before any further work. These
    # are the SAME bytes preflight already read, hashed, and parsed — write_spec_snapshot never
    # re-opens the live file (B2 round-2 finding 1). Every downstream consumer (worker prompt,
    # reviewer prompt, PR title, merge gate) reads THIS snapshot, never the live spec, so a
    # post-approval edit to specs/<id>.yaml cannot change what gets built, judged, or merged.
    snapshot_digest = write_spec_snapshot(att_dir, spec_bytes, digest)
    # Pin the prompt's output contract before starting the attempt. review() reads this snapshot,
    # so an in-flight attempt and its reviewer cannot straddle a repository schema upgrade.
    atomic_write(att_dir / "verdict.schema.json", VERDICT_SCHEMA.read_text())

    # Atomic slot claim + durable 'launching' record BEFORE anything can crash (July lesson:
    # untraceable launches). claim_slot enforces MAX_PARALLEL and one-live-attempt-per-spec under
    # the STATE lock, so concurrent launches (Gate 3 part 3) cannot over-subscribe.
    base_sha = None
    claim_slot(spec_id, {
        "attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
        "spec_digest": digest, "status": "launching", "error_class": None,
        "unit": unit_name(spec_id, n), "created": now(),
    })

    # Box proofs are installed operator code and run under one global lock before the candidate
    # worktree exists. A FAIL, SKIP, missing result, or hash change is terminal and starts no worker.
    try:
        box_observations = run_box_preconditions(att_dir, policy)
    except Exception as e:
        box_observations = {rel: [] for rel in policy["required"]}
        phase_attestation = attestation_record(policy, box_observations)
        result = {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                  "spec_digest": digest, "status": "error_launch",
                  "error_class": ERR_TEST_NOT_RUN,
                  "detail": f"box-precondition harness failed before candidate launch: {e}",
                  "attestation": phase_attestation, "finished": now()}
        atomic_write(att_dir / "test-attestation.json", json.dumps(phase_attestation, indent=2))
        atomic_write(att_dir / "result.json", json.dumps(result, indent=2))
        atomic_write(att_dir / "raw-sha256.txt", raw_hashes(att_dir / "raw"))
        write_state(spec_id, {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                              "spec_digest": digest, "status": "error_launch",
                              "error_class": ERR_TEST_NOT_RUN, "detail": result["detail"]})
        die(result["detail"], 16)
    phase_attestation = attestation_record(policy, box_observations)
    box_ok = all(any(o.get("phase") == "box-precondition" and o.get("status") == "PASS"
                     for o in box_observations.get(rel, []))
                 for rel in policy["required"] if policy["modes"][rel] == "box-precondition")
    if not box_ok:
        result = {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                  "spec_digest": digest, "status": "error_launch",
                  "error_class": ERR_TEST_NOT_RUN,
                  "detail": "box-precondition phase did not pass; no candidate worktree or worker started",
                  "attestation": phase_attestation, "finished": now()}
        atomic_write(att_dir / "result.json", json.dumps(result, indent=2))
        atomic_write(att_dir / "raw-sha256.txt", raw_hashes(att_dir / "raw"))
        write_state(spec_id, {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                              "spec_digest": digest, "status": "error_launch",
                              "error_class": ERR_TEST_NOT_RUN, "detail": result["detail"]})
        die(result["detail"], 16)

    try:
        git("fetch", "--quiet", "origin", approval.get("base_branch", AUTOMATION_BASE))
        base_sha = git("rev-parse", f"origin/{approval.get('base_branch', 'ready-for-main')}")
        branch = f"codex/{attempt_id}"
        # T2: use the FROZEN decision from preflight. Never recompute — a second call to
        # isolation_available() here is exactly the downgrade path we are closing.
        wt = worktree_root(iso) / attempt_id
        if wt.exists():
            die(f"worktree {wt} already exists (attempt not unique?)", 9)
        git("worktree", "add", "--quiet", "-b", branch, str(wt), base_sha)
        if iso:
            grant_worker_acl(wt)   # D5: worker (codex-worker) rwx; the operator reads output; .git denied
    except SystemExit:
        result = {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                  "spec_digest": digest, "base_sha": base_sha, "status": "error_launch",
                  "error_class": ERR_LAUNCH, "detail": "base/worktree setup failed",
                  "attestation": phase_attestation, "finished": now()}
        atomic_write(att_dir / "result.json", json.dumps(result, indent=2))
        atomic_write(att_dir / "raw-sha256.txt", raw_hashes(att_dir / "raw"))
        write_state(spec_id, {**read_state(spec_id), "status": "error_launch",
                              "error_class": ERR_LAUNCH,
                              "detail": "base/worktree setup failed"})
        raise

    ceiling_h = float(spec.get("hard_ceiling_hours", DEFAULT_CEILING_HOURS))
    ceiling_s = int(ceiling_h * 3600)
    # B6: the ONE absolute attempt deadline, fixed now. Every phase in _run_pipeline spends down
    # THIS SAME deadline (remaining_ceiling_s) instead of each getting a fresh full ceiling — the
    # outer --user unit below still gets the full ceiling_s as its own RuntimeMaxSec, which is the
    # single hard backstop for the whole pipeline, not a per-phase grant.
    deadline_ts = time.time() + ceiling_s

    # Persist the launch context the unit's _run needs.
    atomic_write(att_dir / "launch.json", json.dumps({
        "attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
        "spec_digest": digest, "spec_snapshot_digest": snapshot_digest,
        # B2: risk_class/needs_network come from `spec`, which is the parse of the SAME bytes that
        # were hashed into `digest` and written as the snapshot (single-read preflight — B2 round-2
        # finding 1). The recorded metadata therefore provably matches the snapshotted, approved
        # spec; the merge gate re-derives these from the verified snapshot bytes anyway.
        "risk_class": spec.get("risk_class", "default"),
        "needs_network": spec.get("needs_network", False),
        "base_sha": base_sha, "branch": branch,
        "base_branch": approval.get("base_branch", AUTOMATION_BASE),
        # R71: model fields from the ONE tested resolver (run pre-side-effects above) — config
        # defaults, approval pin wins, alias map frozen here; review() reads
        # only lc, never the live config.
        "worktree": str(wt),
        **launch_models,
        "test_command": spec["test_command"], "approved_scope": approval["approved_scope"],
        "regression_command": spec.get("regression_command"),
        "regression_test_paths": spec.get("regression_test_paths", []),
        "hard_ceiling_hours": ceiling_h, "deadline_ts": deadline_ts, "remediation": remediation,
        # The probed-and-pinned runtime; _run refuses to execute anything else (round-1 review).
        "worker_runtime": runtime_record,
        "test_runtime": test_runtime_record,
        "execution_policy": policy,
        # T2: the frozen decision + why it was allowed. `exposure_accepted` is the operator's
        # knowing "yes, run this as me" — provenance never overstates the boundary.
        "isolation": iso, "exposure_accepted": (not iso and exposed),
        # R73 Job 3: subagent BUILDs run inside the orchestrator session — provenance names the
        # trust domain plainly (SECURITY.md) instead of claiming a worker envelope that never ran.
        **({"trust_domain": "orchestrator"} if subagent_mode else {}),
        "worker_unit": f"codex-worker-{attempt_id}",
        "test_unit": f"codex-test-{attempt_id}", "created": now(),
    }, indent=2))

    if subagent_mode:
        # R73 Job 3: no unit starts. The orchestrator session now runs the BUILD itself — the
        # launch-written prompt, inside the attempt worktree, with the frozen worker model —
        # writes the subagent's final message to raw/worker-last-message.txt, then hands the
        # attempt to `dispatch continue` for the unchanged grading half. The deadline is already
        # running: continue refuses once deadline_ts is exhausted, and reconcile expires a
        # stale awaiting_build the same way it expires a dead unit.
        lc = json.loads((att_dir / "launch.json").read_text())
        (att_dir / "raw" / "worker-prompt.txt").write_text(worker_prompt_text(att_dir, lc, n))
        write_state(spec_id, {**read_state(spec_id), "status": "awaiting_build",
                              "base_sha": base_sha,
                              "detail": "subagent BUILD pending; grade with `dispatch continue`"})
        print(attempt_id)
        return

    unit = unit_name(spec_id, n)
    dispatch_bin = str(ROOT / "scripts" / "dispatch")
    # B6 round-2 finding 3: the outer unit's RuntimeMaxSec is the REMAINING time to the absolute
    # deadline_ts (recomputed HERE, after launch.json was written), not a fresh full ceiling that
    # would start counting only when the unit activates — so systemd hard-caps the WHOLE attempt
    # (worker, tests, regression, review, control-plane) at the one absolute deadline, and cannot
    # drift later than it by the launch offset.
    outer_ceiling_s = remaining_ceiling_s(deadline_ts)
    if outer_ceiling_s <= 0:
        die("attempt deadline already exhausted before the outer unit could launch (B6)", 10)
    cmd = [
        "systemd-run", "--user", f"--unit={unit}", "--collect",
        f"--property=Description=Codex worker {attempt_id}",
        f"--property=RuntimeMaxSec={outer_ceiling_s}",   # hard ceiling (D10) tied to the absolute deadline
        # B6 finding 4: when RuntimeMaxSec fires (or the unit is otherwise stopped), tear down the
        # attempt's independent SYSTEM slice + verify AT STOP TIME, instead of leaving orphaned
        # worker/test/regression units for a later reconcile. Idempotent + state-safe (see
        # cmd_timeout); runs on every stop, including normal completion, where it is a no-op.
        f"--property=ExecStopPost={dispatch_bin} timeout {attempt_id}",
        "--setenv=HOME=" + os.environ.get("HOME", str(OPERATOR_HOME)),
        "--setenv=PATH=" + os.environ.get("PATH", "/usr/bin:/bin"),
        "--setenv=XDG_RUNTIME_DIR=" + os.environ.get("XDG_RUNTIME_DIR", ""),
        dispatch_bin, "_run", attempt_id,
    ]
    cp = run(cmd)
    if cp.returncode != 0:
        detail = f"systemd-run failed: {cp.stderr.strip()}"
        result = {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                  "spec_digest": digest, "base_sha": base_sha, "status": "error_launch",
                  "error_class": ERR_LAUNCH, "detail": detail,
                  "attestation": phase_attestation, "finished": now()}
        atomic_write(att_dir / "result.json", json.dumps(result, indent=2))
        atomic_write(att_dir / "raw-sha256.txt", raw_hashes(att_dir / "raw"))
        write_state(spec_id, {**read_state(spec_id), "status": "error_launch",
                              "error_class": ERR_LAUNCH,
                              "detail": detail})
        die(f"failed to start unit: {cp.stderr.strip()}", 10)

    write_state(spec_id, {**read_state(spec_id), "status": "running", "base_sha": base_sha})
    print(attempt_id)


# ================================================================ _run ========
def _attempt_context(attempt_id: str):
    """Shared _run/_grade prologue: load the frozen attempt context and build the ONE terminal
    finish() writer, so both detached entry points record byte-identically shaped results."""
    spec_id, n = parse_attempt_id(attempt_id)
    att = ATTEMPTS / spec_id / str(n)
    lc = json.loads((att / "launch.json").read_text())
    wt = Path(lc["worktree"])
    raw = att / "raw"

    # Base pin, defense in depth (B3): this async path trusts persisted launch.json and never calls
    # preflight(), so a launch.json carrying a non-target base_branch (older attempts recorded
    # 'integration') would fetch/PR against it. Refuse before any work; preflight already blocks new
    # launches, this closes the persisted-state bypass.
    if lc.get("base_branch", AUTOMATION_BASE) != AUTOMATION_BASE:
        die(f"launch.json base_branch={lc.get('base_branch')!r} is not the automation target "
            f"{AUTOMATION_BASE!r}; refuse (stale/foreign attempt state).", 6)

    if lc.get("worker_mode", "external-cli") == "subagent":
        iso_desc = ("subagent BUILD in the orchestrator trust domain (SECURITY.md); test phase "
                    + ("D5-isolated, network-off" if lc.get("isolation")
                       else "same-user (the operator) fallback"))
    else:
        iso_desc = ("D5: codex-worker uid, systemd-hardened, the operator's home inaccessible, test "
                    "phase network-off" if lc.get("isolation") else "same-user (the operator) fallback, "
                    "codex bwrap sandbox")

    def finish(status: str, err_class, **extra) -> None:
        try:
            phase_attestation = json.loads((att / "test-attestation.json").read_text())
        except Exception:
            phase_attestation = {"policy": lc.get("execution_policy"), "required": [],
                                 "tests": {}, "attested": False,
                                 "detail": "phase-aware attestation missing or unreadable"}
        result = {
            "attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
            "spec_digest": lc["spec_digest"], "base_sha": lc["base_sha"],
            "worker_model": lc["worker_model"], "reviewer_model": lc["reviewer_model"],
            "isolation": iso_desc,
            "test_command": lc["test_command"], "status": status,
            "error_class": err_class, "commit_policy": "orchestrator-commits (G1-A/C)",
            "attestation": phase_attestation, "finished": now(), **extra,
        }
        atomic_write(att / "raw-sha256.txt", raw_hashes(raw))
        atomic_write(att / "result.json", json.dumps(result, indent=2))
        write_state(spec_id, {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                              "spec_digest": lc["spec_digest"], "status": status,
                              "error_class": err_class, "unit": unit_name(spec_id, n),
                              **{k: extra[k] for k in ("worker_commit", "pr_url", "detail",
                                                       "worker_exit") if k in extra}})
        sys.exit(0 if status == "passed_pr_opened" else 1)

    return spec_id, n, att, lc, wt, raw, finish


def _run(attempt_id: str) -> None:
    """Runs INSIDE the systemd unit. The full attempt pipeline (Gate 1 steps 3-9)."""
    spec_id, n, att, lc, wt, raw, finish = _attempt_context(attempt_id)
    try:
        _run_pipeline(attempt_id, spec_id, n, att, lc, wt, raw, finish)
    except SystemExit:
        raise
    except Exception as e:  # any unexpected failure still leaves a terminal record
        import traceback
        (raw / "run-traceback.txt").write_text(traceback.format_exc())
        finish("failed_worker_error", ERR_WORKER, detail=f"dispatch _run crashed: {e}")


def _grade(attempt_id: str) -> None:
    """Runs INSIDE the systemd unit started by `dispatch continue` (R73 Job 3): the grading half
    for a subagent-mode attempt whose BUILD the orchestrator session already ran."""
    spec_id, n, att, lc, wt, raw, finish = _attempt_context(attempt_id)
    try:
        # Round-1 blocking 1 (defense in depth behind continue's locked claim, and FIRST — before
        # anything that can write a result): grade ONLY an attempt whose canonical state is this
        # attempt, claimed 'running'. A terminal label (cancel/reconcile/timeout won the race) or
        # a foreign/absent state must never be overwritten by a late grading unit — refuse
        # WITHOUT writing anything.
        st = read_state(spec_id) or {}
        if st.get("attempt_id") != attempt_id or st.get("status") != "running":
            die(f"_grade refuses: canonical state is "
                f"{st.get('status') if st.get('attempt_id') == attempt_id else 'foreign/absent'!r} "
                f"for this attempt, not the 'running' claim `dispatch continue` writes — a "
                f"lifecycle operation owns this attempt now; nothing is overwritten.", 8)
        # Frozen-mode guard, mirror of _run_pipeline's: grading-only entry is for subagent
        # records exclusively; an external-CLI record reaching _grade would skip its worker.
        if lc.get("worker_mode", "external-cli") != "subagent":
            finish("error_launch", ERR_LAUNCH,
                   detail=f"launch record froze worker_mode="
                          f"{lc.get('worker_mode', 'external-cli')!r}; _grade only accepts "
                          f"subagent attempts — external-CLI attempts run their whole pipeline "
                          f"in _run")
        # T2, same doctrine as the BUILD half: an unisolated TEST phase without a recorded
        # operator exposure acceptance is a tampered/hand-edited record — refuse.
        # error_launch, not failed_launch: the refusal must be TERMINAL so `dispatch await`
        # resolves it immediately.
        if not lc.get("isolation", False) and not lc.get("exposure_accepted"):
            finish("error_launch", ERR_NO_ISOLATION,
                   detail="launch record has isolation:false without a recorded operator "
                          "exposure acceptance — refusing to run the spec test as the operator")
        # B6: the ONE absolute deadline frozen at launch keeps running through the BUILD; a
        # legacy-free subagent record always carries deadline_ts (frozen by cmd_launch).
        deadline_ts = lc.get("deadline_ts")
        if deadline_ts is None:
            finish("error_launch", ERR_LAUNCH,
                   detail="subagent launch record lacks deadline_ts (corrupt launch.json); "
                          "fail closed")
        lc["deadline_ts"] = deadline_ts
        vendors = lc_frozen_vendor_fields(lc)
        if vendors is None:
            finish("error_launch", ERR_LAUNCH,
                   detail="launch record carries a partial set of frozen vendor fields (corrupt "
                          "launch.json); fail closed")
        if VENDOR_ADAPTERS is None:
            finish("error_launch", ERR_LAUNCH,
                   detail=f"vendor adapters failed to load at dispatcher start "
                          f"({VENDOR_ADAPTERS_ERR}); fail closed")
        try:
            worker_adapter = VENDOR_ADAPTERS.get_worker_adapter(vendors["worker_vendor"])
        except Exception as exc:
            finish("error_launch", ERR_LAUNCH,
                   detail=f"worker adapter unavailable for vendor "
                          f"{vendors.get('worker_vendor')!r}: {exc}; fail closed")
        # Round-1 major 1: frozen mode must agree with the frozen vendor's registered adapter.
        if worker_adapter.mode != "subagent":
            finish("error_launch", ERR_LAUNCH,
                   detail=f"launch record froze worker_vendor="
                          f"{vendors['worker_vendor']!r} (registered mode "
                          f"{worker_adapter.mode!r}) together with worker_mode=subagent — "
                          f"corrupt launch record; fail closed")
        last_message = worker_adapter.recover_last_message(raw, lc.get("isolation", False))
        _grade_phase(attempt_id, spec_id, n, att, lc, wt, raw, finish,
                     worker_adapter, None, "", last_message)
    except SystemExit:
        raise
    except Exception as e:  # any unexpected failure still leaves a terminal record
        import traceback
        (raw / "grade-traceback.txt").write_text(traceback.format_exc())
        finish("failed_worker_error", ERR_WORKER, detail=f"dispatch _grade crashed: {e}")


def cmd_continue(attempt_id: str) -> None:
    """Hand a subagent-mode attempt's finished BUILD to the unchanged grading half (R73 Job 3).
    Fail-closed preconditions, then the SAME detached-unit shape as cmd_launch, so await/status/
    cancel/timeout/reconcile treat the attempt identically from here on."""
    spec_id, n = parse_attempt_id(attempt_id)
    att = ATTEMPTS / spec_id / str(n)
    lc_path = att / "launch.json"
    if not lc_path.exists():
        die(f"no launch record for {attempt_id} (launch it first)", 6)
    lc = json.loads(lc_path.read_text())
    if lc.get("worker_mode", "external-cli") != "subagent":
        die(f"{attempt_id} froze worker_mode="
            f"{lc.get('worker_mode', 'external-cli')!r}; `dispatch continue` only grades "
            f"subagent attempts — external-CLI attempts run end to end from launch.", 6)
    # Round-1 major 1: the frozen MODE must agree with the frozen VENDOR's registered adapter —
    # a claude/external-cli or codex/subagent record is corrupt, not routable.
    if VENDOR_ADAPTERS is None:
        die(f"vendor adapters failed to load at dispatcher start ({VENDOR_ADAPTERS_ERR}); "
            f"fail closed.", 6)
    try:
        registered_mode = VENDOR_ADAPTERS.worker_mode(lc.get("worker_vendor"))
    except Exception as exc:
        die(f"{attempt_id} froze worker_vendor={lc.get('worker_vendor')!r} with no registered "
            f"adapter ({exc}); corrupt launch record — refuse.", 6)
    if registered_mode != "subagent":
        die(f"{attempt_id} froze worker_vendor={lc.get('worker_vendor')!r} whose registered "
            f"mode is {registered_mode!r}, but worker_mode=subagent — corrupt launch record; "
            f"refuse.", 6)
    if not (att / "raw" / "worker-last-message.txt").exists():
        die("refusing to grade: raw/worker-last-message.txt is missing — the orchestrator "
            "records the subagent's final message before continue (a BUILD that produced no "
            "message was not completed; cancel the attempt instead).", 6)
    # Round-1 blocking 4: BUILD provenance. The orchestrator writes raw/subagent-receipt.json
    # recording which model it launched; continue refuses a missing/invalid receipt or one whose
    # model is not the launch-frozen worker model. This is orchestrator-ATTESTED provenance
    # inside its own trust domain (SECURITY.md is explicit that it is not third-party proof) —
    # what the machine enforces is that the attestation exists, is well-formed, and matches the
    # frozen launch decision before any commit is attributed to that model.
    receipt_path = att / "raw" / "subagent-receipt.json"
    if not receipt_path.exists():
        die("refusing to grade: raw/subagent-receipt.json is missing — the orchestrator records "
            "the subagent model it launched (and the harness pin in effect) before continue.", 6)
    try:
        receipt = json.loads(receipt_path.read_text())
    except Exception as e:
        die(f"refusing to grade: raw/subagent-receipt.json is not valid JSON ({e}).", 6)
    if not isinstance(receipt, dict) or receipt.get("model") != lc.get("worker_model"):
        die(f"refusing to grade: subagent receipt model "
            f"{receipt.get('model') if isinstance(receipt, dict) else receipt!r} does not match "
            f"the launch-frozen worker_model {lc.get('worker_model')!r} — the BUILD that ran is "
            f"not the BUILD this attempt froze.", 6)
    # Round-2 major 1: the receipt's REQUIRED shape is the addendum's — the launched model AND
    # the harness model pin in effect ('none' when no pin was set). A receipt that omits the pin
    # hides exactly the landmine the receipt exists to record (a harness env pin silently
    # overriding the launched model), so it refuses.
    pin = receipt.get("harness_pin")
    if not isinstance(pin, str) or not pin:
        die("refusing to grade: subagent receipt lacks a harness_pin string — record the "
            "CLAUDE_CODE_SUBAGENT_MODEL pin in effect at BUILD time, or 'none'.", 6)
    deadline_ts = lc.get("deadline_ts")
    if deadline_ts is None:
        die(f"{attempt_id} launch record lacks deadline_ts (corrupt); refuse.", 6)
    unit = unit_name(spec_id, n)
    dispatch_bin = str(ROOT / "scripts" / "dispatch")
    # ONE state-lock hold spans verify → flip → unit start (round-1 blocking 1): cancel and
    # reconcile serialize on this same lock for their own writes, so after we verify
    # awaiting_build nothing can relabel the attempt terminal before the grading unit exists;
    # conversely a cancel that got the lock first already flipped the status and our verify
    # refuses. systemd-run under flock is milliseconds; correctness beats the stall.
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            st = read_state(spec_id) or {}
            if st.get("attempt_id") != attempt_id or st.get("status") != "awaiting_build":
                die(f"{attempt_id} is not awaiting a BUILD (state: "
                    f"{st.get('status') if st.get('attempt_id') == attempt_id else 'foreign/absent'}); "
                    f"continue grades exactly one finished subagent BUILD.", 8)
            # B6: the grading unit's RuntimeMaxSec is the REMAINING time to the launch-frozen
            # absolute deadline — the BUILD already spent its share. Exhausted ⇒ the addendum's
            # terminal error_timeout (durable, TERMINAL), never a zero-ceiling unit.
            outer_ceiling_s = remaining_ceiling_s(deadline_ts)
            if outer_ceiling_s <= 0:
                atomic_write(STATE / f"{spec_id}.json",
                             json.dumps({**st, "status": "error_timeout",
                                         "error_class": ERR_TIMEOUT,
                                         "detail": "attempt deadline exhausted during the "
                                                   "subagent BUILD (single absolute ceiling, "
                                                   "B6); re-launch as a fresh attempt",
                                         "updated": now()}, indent=2))
                die("attempt deadline already exhausted before grading could start (B6)", 10)
            # 'running' lands BEFORE the unit starts (the started _grade reads its own state and
            # must see the claim, not race it); a failed start rolls the claim to error_launch —
            # all under the same lock hold, so no observer sees a half-made claim.
            atomic_write(STATE / f"{spec_id}.json",
                         json.dumps({**st, "status": "running",
                                     "detail": "grading (dispatch continue)",
                                     "updated": now()}, indent=2))
            cmd = [
                "systemd-run", "--user", f"--unit={unit}", "--collect",
                f"--property=Description=Grade subagent attempt {attempt_id}",
                f"--property=RuntimeMaxSec={outer_ceiling_s}",
                f"--property=ExecStopPost={dispatch_bin} timeout {attempt_id}",
                "--setenv=HOME=" + os.environ.get("HOME", str(OPERATOR_HOME)),
                "--setenv=PATH=" + os.environ.get("PATH", "/usr/bin:/bin"),
                "--setenv=XDG_RUNTIME_DIR=" + os.environ.get("XDG_RUNTIME_DIR", ""),
                dispatch_bin, "_grade", attempt_id,
            ]
            cp = run(cmd)
            if cp.returncode != 0:
                atomic_write(STATE / f"{spec_id}.json",
                             json.dumps({**st, "status": "error_launch",
                                         "error_class": ERR_LAUNCH,
                                         "detail": f"systemd-run failed starting the grading "
                                                   f"unit: {cp.stderr.strip()}",
                                         "updated": now()}, indent=2))
                die(f"failed to start grading unit: {cp.stderr.strip()}", 10)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)
    print(attempt_id)


def run_candidate_test_phases(lc: dict, wt: Path, worker_commit: str, att: Path,
                              deadline_ts: float, substituted: list[str]) -> dict:
    """Run installed test code in its assigned candidate context and return full attestation.
    deadline_ts (B6) is the ONE absolute attempt deadline; each installed test gets only the time
    remaining to it (recomputed per test, since prior tests in this loop spend the same deadline),
    never a fresh full ceiling, and shares the attempt's systemd slice for teardown."""
    policy = lc["execution_policy"]
    try:
        installed_commit = git("rev-parse", "HEAD", cwd=ROOT)
        # execution_policy() alone would NOT catch a dirty-but-uncommitted tests/ file: it reads
        # only the git tree, so a working-tree edit that never got committed leaves HEAD (and thus
        # the git-tree content) unchanged while still poisoning what actually executes below.
        # grader_drift() is the explicit, mandatory working-tree-vs-HEAD comparison (B4 fix).
        drift = grader_drift(installed_commit, ROOT)
        if drift:
            raise ValueError("grader input drifted from the working tree at pinned commit "
                             f"{installed_commit[:9]}: " + "; ".join(drift))
        current = execution_policy(ROOT, installed_commit)
    except ValueError as e:
        current = None
        policy_error = str(e)
    else:
        policy_error = ""
    try:
        existing = json.loads((att / "test-attestation.json").read_text())
        observations = {rel: list(existing.get("tests", {}).get(rel, {}).get("observations", []))
                        for rel in policy["required"]}
    except Exception:
        observations = {rel: [] for rel in policy["required"]}

    if current != policy:
        for rel in policy["required"]:
            observations[rel].append({"phase": policy["modes"][rel], "status": "FAIL",
                "subject": f"candidate commit {worker_commit}", "identity": OPERATOR_USER,
                "candidate_commit": worker_commit,
                "manifest_sha256": policy["manifest_sha256"],
                "test_sha256": policy["test_sha256"][rel], "started": now(), "finished": now(),
                "exit_status": None, "log": None, "log_sha256": None,
                "claim": f"installed execution policy/test set changed before candidate phases: {policy_error}"})
        return attestation_record(policy, observations)

    runtime = lc.get("test_runtime")
    runtime_ok = test_runtime_matches(runtime)
    for rel in policy["required"]:
        assigned = policy["modes"][rel]
        # Box tests retain an isolated observation, but only their pre-launch box PASS can satisfy
        # attestation. All other non-read tests are graded in candidate isolation.
        phase = "candidate-read" if assigned == "candidate-read" else "candidate-isolated"
        log = att / "raw" / f"{phase}-{Path(rel).stem}.log"
        started = now()
        # B4 fix: hash/execute the COMMITTED blob, not whatever is currently on disk. grader_drift
        # above already proved the working tree matches installed_commit for tests/, so this is
        # provably the same content ROOT/rel holds right now — computing it independently here
        # (rather than trusting that invariant to still hold) closes the TOCTOU window between the
        # drift check and this execution.
        committed_bytes = git_show_bytes(policy["installed_commit"], rel, cwd=ROOT)
        test_before = hashlib.sha256(committed_bytes).hexdigest()
        manifest_before = policy["manifest_sha256"]
        test_after = test_before   # overwritten with the hash of the bytes we ACTUALLY executed
        if phase == "candidate-isolated":
            phase_ceiling_s = remaining_ceiling_s(deadline_ts)
            if not runtime_ok:
                log.write_text("trusted test runtime changed, vanished, or lost root-only trust\n")
                rc = 125
            elif phase_ceiling_s <= 0:
                log.write_text("attempt deadline exhausted before this required test could start "
                                "(single absolute ceiling, B6); refusing\n")
                rc = 124
            else:
                # Materialize the committed blob to a private path and bind THAT onto wt/rel — the
                # sandboxed test never reads ROOT/rel off the (possibly racing) working tree.
                materialized_dir = att / "materialized"
                materialized_dir.mkdir(parents=True, exist_ok=True)
                materialized = materialized_dir / f"{Path(rel).stem}-{test_before[:12]}.sh"
                materialized.write_bytes(committed_bytes)
                materialized.chmod(0o755)
                binds = [(runtime["root"], runtime["root"]),
                         (str(materialized), str(wt / rel))]
                with open(log, "w") as out:
                    cp = isolated_run(
                        f"{lc['test_unit']}-{Path(rel).stem[:24]}",
                        ["bash", "-c", '[ "$(id -un)" = codex-worker ] || exit 126; exec bash "$1"',
                         "installed-phase-runner", str(wt / rel)],
                        cwd=str(wt), rw_paths=[], private_network=True,
                        ceiling_s=phase_ceiling_s, stdout=out, stderr=subprocess.STDOUT,
                        binds=binds, env_extra={"ORCH_TEST_PY": runtime["python"]},
                        slice_name=attempt_slice(lc["attempt_id"]))
                rc = cp.returncode
                test_after = sha256_file(materialized)   # the bytes actually bound + executed
            identity = WORKER_USER
            claim = ("installed test code exercised the exact candidate commit as codex-worker"
                     if assigned == "candidate-isolated" else
                     "isolated observation retained; box-precondition PASS alone grades the host boundary")
        else:
            # candidate-read graders (plain_language.sh, prose_cap.sh) self-locate via
            # dirname("$0")/.. (INSTALLED_ROOT) and read pinned data — tests/banned-terms.txt and,
            # for other operator-side graders, scripts/dispatch.py. B4: run from an IMMUTABLE grader
            # tree checked out OUTSIDE the working tree, with cwd + $0 in that tree, so INSTALLED_ROOT
            # and every data dependency are the pinned commit's and no working-tree path is opened for
            # execution; the candidate under grade is read via ORCH_TEST_TARGET_ROOT/COMMIT; hash the
            # file actually executed. B6: this phase runs no systemd unit but still consumes wall-clock
            # against the ONE absolute deadline — cap the run with a `timeout` prefix tied to remaining
            # time and refuse once none remains, so it can neither start after nor run past deadline.
            identity = execution_identity()
            prefix = deadline_timeout_prefix(deadline_ts)
            if prefix is None:
                log.write_text("attempt deadline exhausted before this candidate-read test could "
                                "start (single absolute ceiling, B6); refusing\n")
                rc = 124
                claim = "refused: attempt deadline exhausted before candidate-read (single absolute ceiling, B6)"
            else:
                env = {"HOME": "/nonexistent", "USER": OPERATOR_USER, "LOGNAME": OPERATOR_USER,
                       "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
                       "GIT_NO_REPLACE_OBJECTS": "1", "ORCH_TEST_TARGET_ROOT": str(wt),
                       "ORCH_TEST_TARGET_COMMIT": worker_commit}
                with materialized_grader_tree(policy["installed_commit"], ROOT) as gtree:
                    run_path = _grader_run_path(gtree, rel)
                    test_before = sha256_file(run_path)   # pinned checkout == committed blob
                    with open(log, "w") as out:
                        cp = subprocess.run([*prefix, "bash", str(run_path)], cwd=str(gtree), env=env,
                                            stdin=subprocess.DEVNULL, stdout=out,
                                            stderr=subprocess.STDOUT)
                    rc = cp.returncode
                    test_after = sha256_file(run_path)   # the bytes actually executed
                claim = "installed policy read exact candidate Git blobs as data; no candidate bytes executed"
        # B4 round-3: re-hash the manifest from the PINNED commit, not the working tree — the graders
        # ran against the materialized (pinned) manifest, so a mid-run working-tree manifest swap
        # must neither pass a stale grade nor fail a pinned one. Commit movement is caught separately
        # by the installed_commit_after check below.
        manifest_after = hashlib.sha256(git_show_bytes(
            policy["installed_commit"], "tests/execution-policy.tsv", cwd=ROOT)).hexdigest()
        status = _status_for_exit(rc)
        if test_after != test_before or manifest_after != manifest_before:
            status = "FAIL"
        observations.setdefault(rel, []).append({
            "phase": phase, "status": status, "subject": f"candidate commit {worker_commit}",
            "identity": identity, "candidate_commit": worker_commit,
            "installed_commit": policy["installed_commit"],
            "installed_commit_after": None,
            "manifest_sha256": manifest_before, "test_sha256": test_before,
            "manifest_sha256_after": manifest_after, "test_sha256_after": test_after,
            "runtime_sha256": runtime.get("tree_sha256") if phase == "candidate-isolated" and runtime else None,
            "runtime_sha256_after": None,
            "runtime_interpreter_sha256": (runtime.get("interpreter_sha256")
                                           if phase == "candidate-isolated" and runtime else None),
            "runtime_requirements_sha256": (runtime.get("requirements_sha256")
                                            if phase == "candidate-isolated" and runtime else None),
            "started": started, "finished": now(), "exit_status": rc,
            "log": str(log.relative_to(att)), "log_sha256": sha256_file(log), "claim": claim})
        atomic_write(att / "test-attestation.json",
                     json.dumps(attestation_record(policy, observations), indent=2))
    runtime_after = trusted_test_runtime()
    installed_commit_after = git("rev-parse", "HEAD", cwd=ROOT)
    for rel_observations in observations.values():
        for obs in rel_observations:
            if obs.get("phase") not in ("candidate-isolated", "candidate-read"):
                continue
            obs["installed_commit_after"] = installed_commit_after
            if installed_commit_after != policy["installed_commit"]:
                obs["status"] = "FAIL"
            if obs.get("phase") == "candidate-isolated":
                obs["runtime_sha256_after"] = (runtime_after.get("tree_sha256")
                                               if runtime_after else None)
                if runtime_after != runtime:
                    obs["status"] = "FAIL"
    result = attestation_record(policy, observations)
    result["required_tests_restored_from_parent"] = substituted
    atomic_write(att / "test-attestation.json", json.dumps(result, indent=2))
    return result


def worker_prompt_text(att: Path, lc: dict, n: int) -> str:
    """The worker's BUILD prompt, from the verified launch snapshot — ONE builder for both
    execution modes (R73 Job 3), so a subagent worker is told exactly what the external-CLI
    worker would be. Fixed preamble; planning policy per policy-note item 2; commit policy per
    G1-A/C. B2: the SNAPSHOT taken at launch, never the live spec file — an edit to
    specs/<id>.yaml after approval must not change what the worker is told to build; the
    snapshot bytes are re-hashed against the recorded digest on this read."""
    preamble = (
        "Implement this spec. Modify only in-scope paths. Run the test command until it exits 0. "
        "Leave your changes in the working tree; do NOT commit or push — the orchestrator commits "
        "your work.\n"
        "Inspect relevant code and tests before editing. For non-trivial tasks, maintain a "
        "concise, revisable implementation checklist covering intended files and verification; "
        "skip it for trivial tasks.\n"
        "Implement the simplest, cleanest solution that satisfies the spec — no abstractions or "
        "configurability beyond what the spec designs. Fix what matters most first: do not "
        "engineer around small edge cases the spec does not name — note them in your final "
        "report instead. Keep the diff surgical: touch no adjacent "
        "code, comments, or formatting; match the existing style; remove only what your own "
        "change orphaned. State non-obvious assumptions in your final report.\n"
        "The approved spec and evidence gates remain binding. If "
        "discovery invalidates the spec or approved scope (impossible acceptance criteria, wrong "
        "test command, inadequate scope), stop and report SPEC_BLOCKED on its own line followed by "
        "the reason — never improvise beyond the spec."
    )
    prompt = preamble + "\n\n=== SPEC ===\n" + snapshot_spec_text(
        att, lc.get("spec_snapshot_digest") or lc["spec_digest"])
    # Gate 4: a remediation attempt must address the SPECIFIC findings of the failed attempt —
    # inside the approved scope, producing new evidence in this new attempt directory.
    rem = lc.get("remediation")
    if rem:
        prompt += (
            f"\n\n=== REMEDIATION (attempt {n}; remediation #{rem['remediation_number']} of "
            f"max {rem['limit']}) ===\n"
            f"A previous attempt (#{rem['of_attempt']}) FAILED. Your job is to address these "
            f"specific findings — nothing else. Stay strictly within the approved scope. If the "
            f"findings cannot be addressed within the spec and scope, report SPEC_BLOCKED.\n"
            + json.dumps(rem["findings"], indent=2)
        )
    return prompt


def _run_pipeline(attempt_id, spec_id, n, att, lc, wt, raw, finish) -> None:
    # --- step 3: run the worker (scrubbed env, network off) --------------------
    prompt = worker_prompt_text(att, lc, n)
    (raw / "worker-prompt.txt").write_text(prompt)

    # T2: consume the FROZEN launch decision — never recompute isolation here. A launch record that
    # says "unisolated" without a recorded operator acceptance is not a thing cmd_launch can produce,
    # so if we see one, the record was tampered with or hand-edited: refuse rather than run worker
    # code as the operator on the strength of a file.
    iso = lc.get("isolation", False)
    if not iso and not lc.get("exposure_accepted"):
        finish("error_launch", ERR_NO_ISOLATION,
               detail="launch record has isolation:false without a recorded operator exposure "
                      "acceptance — refusing to run worker code as the operator")
    # B6: ONE absolute attempt deadline, fixed at launch (cmd_launch). Every phase below spends down
    # THIS SAME deadline via remaining_ceiling_s() — never a fresh full ceiling per phase. Fall back
    # to deriving one now only for a launch.json that predates this field.
    deadline_ts = lc.get("deadline_ts")
    if deadline_ts is None:
        deadline_ts = time.time() + float(lc.get("hard_ceiling_hours", DEFAULT_CEILING_HOURS)) * 3600
    # Make the resolved deadline authoritative for every phase reached through lc (esp. review()).
    lc["deadline_ts"] = deadline_ts
    # R73 Job 2: worker CLI mechanics live behind the vendor adapter, selected by the FROZEN
    # worker vendor — same fail-closed doctrine as review(): the module pinned at dispatcher
    # import, corrupt/partial vendor records and unknown vendors refuse before any worker runs.
    # Round-3 review (major): these refusals record error_launch — the canonical TERMINAL
    # infrastructure status (`dispatch await` resolves it immediately; it consumes no
    # remediation budget) — never failed_launch, which is in neither TERMINAL nor LIVE.
    vendors = lc_frozen_vendor_fields(lc)
    if vendors is None:
        finish("error_launch", ERR_LAUNCH,
               detail="launch record carries a partial set of frozen vendor fields (corrupt "
                      "launch.json); fail closed — no worker was invoked")
    if VENDOR_ADAPTERS is None:
        finish("error_launch", ERR_LAUNCH,
               detail=f"vendor adapters failed to load at dispatcher start "
                      f"({VENDOR_ADAPTERS_ERR}); fail closed — no worker was invoked")
    try:
        worker_adapter = VENDOR_ADAPTERS.get_worker_adapter(vendors["worker_vendor"])
    except Exception as exc:
        finish("error_launch", ERR_LAUNCH,
               detail=f"worker adapter unavailable for vendor "
                      f"{vendors.get('worker_vendor')!r}: {exc}; fail closed — "
                      f"no worker was invoked")
    # R73 Job 3: this pipeline invokes an EXTERNAL worker CLI. A record frozen as subagent mode
    # has no CLI to invoke — its BUILD runs inside the orchestrator session and grading enters
    # through `dispatch continue`. Refuse rather than run the wrong envelope (absent field =
    # legacy external-cli record).
    if lc.get("worker_mode", "external-cli") != "external-cli":
        finish("error_launch", ERR_LAUNCH,
               detail="launch record froze worker_mode="
                      f"{lc.get('worker_mode')!r}; the external-CLI worker pipeline refuses it — "
                      "subagent BUILDs are graded via `dispatch continue`")
    # Round-1 major 1: frozen mode must agree with the frozen vendor's registered adapter — a
    # codex/subagent (caught above) or claude/external-cli record is corrupt, not routable.
    if worker_adapter.mode != "external-cli":
        finish("error_launch", ERR_LAUNCH,
               detail=f"launch record froze worker_vendor={vendors['worker_vendor']!r} "
                      f"(registered mode {worker_adapter.mode!r}) together with "
                      f"worker_mode=external-cli — corrupt launch record; fail closed — "
                      f"no worker was invoked")
    with open(raw / "events.jsonl", "w") as ev, open(raw / "worker-stderr.txt", "w") as er:
        if iso:
            # D5: worker runs as codex-worker in a hardened system service. Codex's own sandbox is
            # OFF (-s danger-full-access) because it won't construct under the bind-mounted UID;
            # ProtectSystem=strict + ReadWritePaths confine writes and InaccessiblePaths=the operator's home
            # + DAC confine reads. --output-last-message is dropped (worker can't write the operator's home);
            # the final message is recovered from the JSONL stream.
            rt = lc.get("worker_runtime")
            if rt:
                # Re-verify every pinned source immediately before the service starts (probe->run
                # TOCTOU, round-2 review). No pins, a stale pin, or a runtime that lost its file
                # trust all refuse — fail closed.
                pins = rt.get("pins") or {}
                stale = []
                for src, want in pins.items():
                    sp = Path(src)
                    try:
                        got = _tree_fingerprint(sp) if sp.is_dir() else runtime_fingerprint(sp)
                    except OSError:
                        got = "<unreadable>"
                    if got != want:
                        stale.append(src)
                entry_ok = _trusted_runtime_file(Path(rt["entry"]), want_exec=False) is not None
                # Re-verify whole-tree trust for every mounted DIRECTORY, not just the entry file
                # (round-3 review): a vendor file inside the mount could have flipped to
                # worker-writable since launch even if its bytes still match a pin.
                tree_ok = all(trusted_runtime_tree(Path(src)) for src, _dst in rt["binds"]
                              if Path(src).is_dir())
                if stale or not pins or not entry_ok or not tree_ok:
                    # Round-1 review (medium 3): codex message stays byte-identical ("Codex").
                    rt_vendor = ("Codex" if vendors["worker_vendor"] == "codex"
                                 else vendors["worker_vendor"])
                    finish("failed_worker_error", ERR_WORKER,
                           detail=f"{rt_vendor} runtime changed, vanished or lost trust between launch "
                                  f"and run (stale: {stale or 'no pins recorded'}, "
                                  f"tree_ok={tree_ok}); refusing")
                argv_prefix, binds = rt["argv"], [tuple(b) for b in rt["binds"]]
            else:  # launch record predates runtime pinning: resolve live (adapter delegates
                # to the module-level resolver for the FROZEN vendor — trust machinery stays here)
                runtime = worker_adapter.runtime(worker_runtime_resolver(vendors["worker_vendor"]))
                if runtime is None:
                    finish("failed_worker_error", ERR_WORKER,
                           detail="no worker-launchable Codex runtime (npm package + system "
                                  "node, or a native ELF binary)"
                                  if vendors["worker_vendor"] == "codex" else
                                  f"no worker-launchable {vendors['worker_vendor']} runtime "
                                  f"(native ELF binary)")
                argv_prefix, binds, _entry = runtime
            # Kimi slice 3: the frozen alias map rides to the worker adapter — kimi's CLI takes
            # the provider alias, not the relay model id; codex ignores the keyword (verbatim
            # contract, tests/dispatch_worker_adapter.sh). A kimi record whose frozen aliases
            # lack the required entry is refused by the adapter (ValueError) and recorded
            # TERMINALLY here — never invoked with a raw relay id (round-1 review, medium 4).
            try:
                argv = worker_adapter.build_argv(lc["worker_model"], lc["worker_effort"], wt,
                                                 prompt, isolated=True, argv_prefix=argv_prefix,
                                                 cli_aliases=lc.get("cli_aliases") or {})
            except ValueError as exc:
                finish("error_launch", ERR_LAUNCH,
                       detail=f"worker argv refused: {exc}")
            worker_ceiling_s = remaining_ceiling_s(deadline_ts)
            if worker_ceiling_s <= 0:
                finish("error_launch", ERR_TIMEOUT,
                       detail="attempt deadline already exhausted before the worker phase could "
                              "start (single absolute ceiling, B6); refusing")
            wc = isolated_run(
                lc["worker_unit"], argv, cwd=str(wt),
                rw_paths=[str(wt), *worker_adapter.iso_rw_paths(WORKER_HOME)],
                private_network=False, ceiling_s=worker_ceiling_s, stdout=ev, stderr=er,
                binds=binds, slice_name=attempt_slice(attempt_id),
                env_extra=worker_adapter.iso_env_extra(WORKER_HOME))
        else:
            # Fallback (fresh box / CI): same-user launch with Codex's bwrap sandbox. No systemd
            # RuntimeMaxSec here, so cap the run itself at the time remaining to the absolute deadline
            # (round-2 finding 3) — a `timeout` wrapper, not just a pre-start check that would let a
            # started worker run arbitrarily far past the deadline. None => no time left => refuse.
            prefix = deadline_timeout_prefix(deadline_ts)
            if prefix is None:
                finish("error_launch", ERR_TIMEOUT,
                       detail="attempt deadline already exhausted before the worker phase could "
                              "start (single absolute ceiling, B6); refusing")
            scrubbed = worker_adapter.worker_env(OPERATOR_HOME, OPERATOR_USER)
            # Kimi slice 3: an adapter may refuse the unisolated envelope outright (kimi does —
            # no --cd, no inner sandbox). cmd_launch already refuses such launches before side
            # effects; this converts a refusal on a hand-carried record into a TERMINAL
            # error_launch instead of an uncaught exception that would strand the attempt.
            try:
                built = worker_adapter.build_argv(
                    lc["worker_model"], lc["worker_effort"], wt, prompt, isolated=False,
                    last_message_path=raw / "worker-last-message.txt",
                    cli_aliases=lc.get("cli_aliases") or {})
            except ValueError as exc:
                finish("error_launch", ERR_LAUNCH,
                       detail=f"worker argv refused: {exc}")
            worker_cmd = [*prefix, *built]
            with open(os.devnull) as devnull:
                wc = subprocess.run(worker_cmd, env=scrubbed, stdin=devnull, stdout=ev, stderr=er)

    stderr_txt = (raw / "worker-stderr.txt").read_text()
    last_message = worker_adapter.recover_last_message(raw, iso)

    _grade_phase(attempt_id, spec_id, n, att, lc, wt, raw, finish,
                 worker_adapter, wc.returncode, stderr_txt, last_message)


def _grade_phase(attempt_id, spec_id, n, att, lc, wt, raw, finish,
                 worker_adapter, worker_exit, stderr_txt, last_message) -> None:
    """Everything AFTER the worker ran: the ONE shared grading half (R73 Job 3). External-CLI
    attempts reach it from _run_pipeline inside their detached unit; subagent attempts reach it
    through `dispatch continue` → _grade. Both modes get byte-identical gates, in the
    pre-split order: SPEC_BLOCKED honor, error classification, path-safety, orchestrator
    commit, integrity, scope, isolated spec test, required-test restoration + attestation,
    optional regression gate, bound review, stale-base guard, push + draft PR. Callers resolve
    lc['deadline_ts'] before entry."""
    iso = lc.get("isolation", False)
    deadline_ts = lc["deadline_ts"]

    # policy-note item 2: worker signalled the spec is unworkable. Old approval is void; a spec
    # revision + new approval digest is required. Terminal, but NOT a worker failure.
    if re.search(r"(^|\n)\s*SPEC_BLOCKED\b", last_message):
        finish("spec_blocked", ERR_SPEC_BLOCKED, worker_exit=worker_exit,
               detail="worker reported SPEC_BLOCKED; spec revision + new approval required",
               worker_message=last_message.strip()[:2000])

    ec = worker_adapter.classify_error(worker_exit, stderr_txt, raw)
    if ec is not None:
        # policy-note item 1: a quota/rate-limit mid-attempt is INTERRUPTED (external capacity),
        # not a merit failure. Preserve evidence, stop; resume ONLY as a fresh attempt when
        # capacity returns. The dispatcher never resumes a partial worktree.
        if ec == ERR_QUOTA:
            finish("interrupted", ERR_QUOTA, worker_exit=worker_exit,
                   detail="Codex quota/rate-limit hit mid-attempt; re-launch as a fresh attempt "
                          "after capacity returns. Never hand-finish this worktree.")
        # NEVER inline stderr here: result.json is pushed as provenance and raw worker stderr can
        # carry secrets (round-1 review). await shows a local-only tail from the gitignored file.
        # The recorded class comes from the dispatcher's own vocabulary: an adapter answer
        # outside it records as the generic worker class (detail keeps the adapter's literal).
        finish("failed_worker_error",
               ec if ec in (ERR_AUTH, ERR_SANDBOX, ERR_WORKER) else ERR_WORKER,
               worker_exit=worker_exit,
               detail=f"worker error class={ec}; stderr kept in raw/worker-stderr.txt")

    # --- D5 path-safety gate: reject planted symlinks/special files BEFORE any operator-context step
    # touches worker output (no later the operator process should be able to follow a link into the operator's files).
    unsafe = validate_worktree_safe(wt)
    if unsafe:
        finish("failed_scope", ERR_SCOPE, worker_exit=worker_exit,
               detail=f"unsafe filesystem entries planted by worker (symlink/fifo/socket/device): "
                      f"{unsafe[:20]}")

    # --- decision G1-A/C: ORCHESTRATOR commits the worktree state --------------
    changed = git("status", "--porcelain=v2", "--untracked-files=all", cwd=wt)
    if not changed.strip():
        finish("failed_worker_error", ERR_WORKER, worker_exit=worker_exit,
               detail="worker produced no changes")
    git("add", "-A", cwd=wt)
    env = os.environ.copy()
    # R73 Job 2: vendor-neutral authorship — the author string is display metadata; authorship
    # VENDOR always derives from the attempt's frozen launch.json (scripts/review B18), never
    # from this name, so a claude worker (Job 3) is not mislabeled as Codex-authored.
    env["GIT_AUTHOR_NAME"] = f"Worker {lc['worker_model']}"
    env["GIT_AUTHOR_EMAIL"] = "codex-worker@orchestrator.local"
    msg = (f"{spec_id}: worker output (attempt {n})\n\n"
           f"Worker {lc['worker_model']} (reasoning={lc['worker_effort']}), packaged by the "
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
    # The spec test_command runs candidate code as codex-worker with private networking. It is
    # supplemental: the installed dispatcher separately runs and records every required test.
    test_runtime = lc.get("test_runtime")
    if iso and not test_runtime_matches(test_runtime):
        finish("failed_test", ERR_TEST_NOT_RUN, worker_commit=worker_commit,
               detail="trusted test runtime changed or lost root-only trust before test phase")
    test_env = ({"ORCH_TEST_PY": test_runtime["python"]} if iso else {})

    # T1b (R26) — HOLD THE GRADER OUT OF THE AGENT'S REACH.
    # T1 made the orchestrator choose WHICH tests are required. That is not enough: the tests still
    # EXECUTE from the worker's worktree, so a candidate whose approved scope includes tests/ can
    # rewrite a required test to `exit 0` and pass the gate honestly. (Demonstrated, not theorised.)
    # Every reward-hacking result in the literature reduces to the agent being able to touch the
    # thing that scores it: METR observed o3 monkey-patching the evaluator and stealing the reference
    # answer on 100% of trajectories for one task.
    #
    # So: the REQUIRED tests are restored from the ORCHESTRATOR's installed copy before the gate runs.
    # A worker's edits to a required test are retained but never satisfy the required set. A changed
    # test becomes authoritative only after it is reviewed, merged, and installed.
    # The spec's own command remains supplemental acceptance evidence and always runs isolated.
    # It never supplies per-test attestation; the installed dispatcher collects that itself below.
    if iso:
        test_ceiling_s = remaining_ceiling_s(deadline_ts)
        if test_ceiling_s <= 0:
            finish("failed_test", ERR_TIMEOUT, worker_commit=worker_commit,
                   detail="attempt deadline exhausted before the spec test phase could start "
                          "(single absolute ceiling, B6); refusing")
        with open(att / "test.log", "w") as tl:
            tcp = isolated_run(
                lc["test_unit"], ["bash", "-c", lc["test_command"]], cwd=str(wt),
                rw_paths=[str(wt)], private_network=True, ceiling_s=test_ceiling_s,
                env_extra=test_env, stdout=tl, stderr=subprocess.STDOUT,
                binds=[(test_runtime["root"], test_runtime["root"])],
                slice_name=attempt_slice(attempt_id))
        test_rc = tcp.returncode
    else:
        # Unisolated fallback: no RuntimeMaxSec, so cap the run at the remaining time to the absolute
        # deadline (B6) — a `timeout` wrapper, not just a pre-start check; export GIT_NO_REPLACE_OBJECTS
        # (B4) so a planted refs/replace can't alter the command's git object reads.
        prefix = deadline_timeout_prefix(deadline_ts)
        if prefix is None:
            finish("failed_test", ERR_TIMEOUT, worker_commit=worker_commit,
                   detail="attempt deadline exhausted before the spec test phase could start "
                          "(single absolute ceiling, B6); refusing")
        tc = run([*prefix, "bash", "-c", lc["test_command"]], cwd=str(wt),
                 env={**os.environ, "GIT_NO_REPLACE_OBJECTS": "1", **test_env})
        (att / "test.log").write_text((tc.stdout or "") + (tc.stderr or ""))
        test_rc = tc.returncode
    if test_rc != 0:
        finish("failed_test", ERR_TEST, worker_commit=worker_commit, test_exit=test_rc)
    post_test_integrity, post_test_ok = integrity(wt, lc["base_sha"], worker_commit)
    if not post_test_ok:
        finish("failed_integrity", ERR_INTEGRITY, worker_commit=worker_commit,
               detail="spec test_command changed the committed candidate worktree",
               integrity=post_test_integrity)

    substituted = []
    try:
        restore_ctx = required_tests()
    except ValueError as e:
        finish("failed_test", ERR_TEST_NOT_RUN, worker_commit=worker_commit,
               detail=f"grader input drift blocked required-test restoration: {e}")
    for rel in restore_ctx["required"]:
        # B4 fix: the ORCHESTRATOR's copy restored into the candidate worktree is the COMMITTED
        # blob at the pinned commit, never ROOT/rel off the working tree.
        try:
            committed_bytes = git_show_bytes(restore_ctx["installed_commit"], rel, cwd=ROOT)
        except ValueError:
            continue
        worker_copy = wt / rel
        if not worker_copy.exists() or worker_copy.read_bytes() != committed_bytes:
            if worker_copy.exists():
                (att / "raw" / f"worker-{Path(rel).name}").write_bytes(worker_copy.read_bytes())
                substituted.append(rel)
            worker_copy.parent.mkdir(parents=True, exist_ok=True)
            worker_copy.write_bytes(committed_bytes)
            worker_copy.chmod(0o755)

    attestation = run_candidate_test_phases(lc, wt, worker_commit, att, deadline_ts, substituted)
    if not attestation["attested"]:
        finish("failed_test", ERR_TEST_NOT_RUN, worker_commit=worker_commit,
               test_exit=test_rc, detail=attestation["detail"])

    # --- step 7.5: OPTIONAL regression-proof gate (holistic-review #1) ----------
    # Prove the change's new test actually CATCHES the intended defect: the human-authored
    # regression_command must FAIL on the base (with the candidate's test files overlaid, so it fails
    # for the right reason) and PASS on the candidate. A vacuous test (passes on base too) is a merit
    # failure. Runs worker-authored code → isolated (network off) like the test phase.
    if lc.get("regression_command"):
        reg = run_regression_gate(lc, wt, worker_commit, att, iso, deadline_ts)
        atomic_write(att / "regression.json", json.dumps(reg, indent=2))
        if reg["result"] != "PASS":
            finish("failed_regression", ERR_REGRESSION, worker_commit=worker_commit, regression=reg)

    # --- step 8: reviewer (bound, fail-closed) --------------------------------
    verdict, vraw = review(att, spec_id, lc, worker_commit, attestation)
    # Round-2 finding 3 / round-3 finding 2: bind the EFFECTIVE reviewer model onto the canonical
    # review record through ONE tested writer (write_review_record), so the attribution is covered
    # by a direct assertion rather than only as an incidental side effect of this pipeline.
    write_review_record(att, verdict, lc["reviewer_model"])
    binary_result = (evaluate_binary_review(
        verdict.get("verdict"), verdict.get("criteria", []),
        verdict.get("scope_finding"), verdict.get("regression_finding"),
        verdict.get("security_findings")) if verdict else None)
    if binary_result != "PASS":
        finish("failed_review", ERR_REVIEW, worker_commit=worker_commit,
               review_verdict=binary_result or "malformed")

    # --- step 8.5: stale-base guard (Gate 3 part 3 — parallelism safety) -------
    # With MAX_PARALLEL>1 a sibling attempt can integrate while this one runs, advancing the base
    # branch. This attempt was reviewed and tested against base_sha; integrating it onto a moved
    # base would land a combination no gate ever saw. Refuse to push. The orchestrator re-launches
    # a FRESH attempt off the new base (all gates re-run) — never a hand-rebase of a reviewed
    # worktree (that would carry a stale review verdict). This is the last check before the attempt
    # becomes visible, so the base cannot move between the check and the push in a way that matters.
    base_branch = lc.get("base_branch", AUTOMATION_BASE)
    current_base, moved = base_moved(wt, base_branch, lc["base_sha"])
    if moved:
        finish("stale_base", ERR_STALE_BASE, worker_commit=worker_commit,
               base_branch=base_branch, base_moved_to=current_base,
               detail=f"base branch '{base_branch}' advanced "
                      f"{lc['base_sha'][:9]} -> {current_base[:9]} during this attempt "
                      f"(a sibling integrated); re-launch a fresh attempt off the new base "
                      f"(all gates re-run). No PR opened.")

    # --- step 9: push + draft PR (orchestrator only) --------------------------
    if git("rev-parse", "HEAD", cwd=wt) != worker_commit:
        finish("failed_integrity", ERR_INTEGRITY, worker_commit=worker_commit,
               detail="head moved after review")
    git("push", "-u", "origin", lc["branch"], cwd=wt)
    # Target the SAME pinned base the attempt was built/tested/reviewed against (B3) — not a separate
    # literal that could drift from base_branch.
    # B2 round-2 finding 3: the PR title comes from the VERIFIED snapshot mapping, not a fresh
    # load_spec() read of the live (possibly post-approval-edited) file.
    snap_title = snapshot_spec(att, lc.get("spec_snapshot_digest") or lc["spec_digest"]).get("title", "")
    pr = run(["gh", "pr", "create", "--draft", "--base",
              base_branch, "--head", lc["branch"],
              "--title", f"{spec_id}: {snap_title}",
              "--body", pr_body(spec_id, lc, worker_commit)], cwd=str(ROOT))
    pr_url = (pr.stdout or "").strip().splitlines()[-1] if pr.returncode == 0 else None
    if pr.returncode != 0:
        finish("failed_worker_error", ERR_WORKER, worker_commit=worker_commit,
               detail=f"pr create failed: {pr.stderr.strip()}")

    hashes = raw_hashes(raw)
    atomic_write(att / "raw-sha256.txt", hashes)
    finish("passed_pr_opened", ERR_NONE, worker_commit=worker_commit, pr_url=pr_url)


# ----------------------------------------------------------- worker helpers ----
# classify_worker and last_agent_message moved into the worker adapter (R73 Job 2,
# scripts/vendor_adapters.py CodexWorker): output recovery and error classification are
# vendor CLI mechanics. The recorded error-class vocabulary (ERR_*) stays defined here.
def valid_attempt_branch(branch, attempt_id: str) -> bool:
    """True only for a branch name that provably belongs to this attempt: exactly one
    namespace segment, a slash, then the exact attempt id (today: codex/SPEC-NNN-n). The
    frozen lc["branch"] is DATA feeding destructive deletion (R73 Job 2 round-1 review,
    blocking) — a corrupt record naming main, ready-for-main, an owner branch, or another
    attempt's branch must never reach `git branch -D` / remote delete."""
    return (isinstance(branch, str)
            and re.fullmatch(r"[A-Za-z0-9._-]+/" + re.escape(attempt_id), branch) is not None)


def base_moved(wt: Path, base_branch: str, base_sha: str) -> tuple[str, bool]:
    """Gate 3 part 3 stale-base guard. Fetch the base branch and compare its current tip to the
    sha this attempt was built and reviewed against. Returns (current_tip, moved). `moved` True
    means a sibling attempt integrated while this one ran, so its review/test verdict no longer
    describes what would land — the attempt must be re-run fresh off the new base."""
    git("fetch", "--quiet", "origin", base_branch, cwd=wt)
    current = git("rev-parse", f"origin/{base_branch}", cwd=wt)
    return current, current != base_sha


def integrity(wt: Path, base: str, wc: str) -> tuple[dict, bool]:
    head = git("rev-parse", "HEAD", cwd=wt)
    # Finding 4: ancestry is an object-graph read — route through git_cp() so a planted refs/replace
    # cannot forge "candidate descends from base" and slip an unrelated tree past the integrity gate.
    desc = git_cp(["merge-base", "--is-ancestor", base, wc], cwd=wt).returncode == 0
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


def _glob_to_regex(g: str) -> re.Pattern:
    """Translate a scope glob to a regex where `*` does NOT cross a path separator.

    fnmatch's `*` matches `/` — so an approved scope of `scripts/lib/*.sh` also permitted
    `scripts/lib/nested/evil.sh`. The scope gate is the only STRUCTURAL defence against a worker
    writing outside its approved paths (everything else is a model being asked nicely), so a `*`
    that silently descends is a hole in the one wall that does not depend on good behaviour.

    Semantics now: `*` matches within one path segment; `**` (and a trailing `/**`) is recursive.
    """
    out, i = [], 0
    while i < len(g):
        c = g[i]
        if c == "*":
            if g[i:i + 2] == "**":            # `**` — recursive, may cross separators
                out.append(".*")
                i += 2
                if g[i:i + 1] == "/":         # `a/**/b` — the `/` is optional (matches `a/b` too)
                    out.append("/?")
                    i += 1
                continue
            out.append("[^/]*")               # `*` — stays inside one segment
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def _match_glob(path: str, globs: list[str]) -> bool:
    for g in globs:
        if g.endswith("/**"):                 # keep the fast, explicit recursive-prefix case
            if path == g[:-3] or path.startswith(g[:-3] + "/"):
                return True
        elif _glob_to_regex(g).match(path):
            return True
    return False


def _warn_scope_overlaps(spec_id: str, in_scope: list[str], depends_on: list[str]) -> None:
    """Advisory only (R88): warn when another PENDING spec's in_scope could touch the same paths,
    so the operator serializes with depends_on BEFORE both are in flight (the binding scope gate
    stays in scope_check). Conservative — false positives are acceptable for advice: identical
    globs, a `dir/**` prefix covering the other glob, or a wildcard-free glob the other side
    matches. Never dies and never changes the launch path: a broken candidate spec, state file,
    or stderr write skips that candidate, and legacy 'merged' completions are skipped because depends_on accepts
    only passed_pr_opened — advising them would turn a working launch into an exit-7 refusal."""
    def covers(a: str, b: str) -> bool:
        if a == b:
            return True
        if a.endswith("/**") and (b == a[:-3] or b.startswith(a[:-3] + "/")):
            return True
        return not any(c in b for c in "*?") and _match_glob(b, [a])

    for path in sorted(SPECS.glob("SPEC-*.yaml")):
        other_id = path.stem
        if other_id == spec_id:
            continue
        try:
            other = yaml.safe_load(path.read_text())
            if not isinstance(other, dict) or other_id in depends_on \
                    or spec_id in other.get("depends_on", []):
                continue
            st = read_state(other_id)
            if st and st.get("status") in ("passed_pr_opened", "merged"):
                continue
            hits = [f"'{a}'" if a == b else f"'{a}' ∩ '{b}'"
                    for a in in_scope for b in other.get("in_scope", [])
                    if covers(a, b) or covers(b, a)]
            if hits:
                # print stays inside the try: a closed/broken stderr must not break the launch
                print(f"dispatch: WARNING scope overlap: {spec_id} ∩ {other_id} "
                      f"({', '.join(hits[:5])}). Add depends_on: [{other_id}] to serialize.",
                      file=sys.stderr)
        except Exception:
            continue


def scope_check(wt: Path, base: str, wc: str, globs: list[str]) -> dict:
    # Finding 4: the scope gate parses this diff to decide what changed — a planted refs/replace
    # could otherwise rewrite the diff and hide an out-of-scope change. Read with replace off.
    cp = git_cp(["diff", "--name-status", "-z", f"{base}..{wc}"], cwd=wt)
    # B14: a failing diff (bad ref, I/O error) yields empty stdout, which parsed as an empty
    # change set and PASSED scope. A diff that did not run cannot certify anything — fail closed.
    if cp.returncode != 0:
        return {"approved_scope": globs, "changed": [], "out_of_scope": [],
                "result": "FAIL",
                "error": f"git diff exited {cp.returncode}: {(cp.stderr or '').strip()[:500]}"}
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


def _verdict_schema_for_attempt(att: Path) -> dict:
    """Use the launch-time contract, with a repo-schema fallback for historical attempts."""
    pinned = att / "verdict.schema.json"
    return json.loads((pinned if pinned.exists() else VERDICT_SCHEMA).read_text())


def attest_tests(observations: dict[str, list[dict]], required: list[str],
                 modes: dict[str, str], policy: dict) -> tuple[bool, str]:
    """Require literal PASS with complete provenance in each test's assigned phase."""
    if not required:
        return False, ("no required tests selected — an empty required-test set cannot certify "
                       "anything (fail closed)")
    problems = []
    for t in required:
        phase = modes.get(t)
        if phase not in EXECUTION_MODES:
            problems.append(f"{t}: invalid assigned phase {phase!r}")
            continue
        assigned = [o for o in observations.get(t, []) if o.get("phase") == phase]
        if not assigned:
            problems.append(f"{t}: NO RESULT in assigned phase {phase}")
            continue
        if len(assigned) != 1:
            problems.append(f"{t}: expected one assigned-phase observation, got {len(assigned)}")
            continue
        passing = []
        for obs in assigned:
            common = (obs.get("status") == "PASS" and obs.get("exit_status") == 0
                      and obs.get("installed_commit") == policy.get("installed_commit")
                      and obs.get("installed_commit_after") == policy.get("installed_commit")
                      and obs.get("manifest_sha256") == policy.get("manifest_sha256")
                      and obs.get("manifest_sha256_after") == policy.get("manifest_sha256")
                      and obs.get("test_sha256") == policy.get("test_sha256", {}).get(t)
                      and obs.get("test_sha256_after") == policy.get("test_sha256", {}).get(t)
                      and all(obs.get(k) for k in ("subject", "identity", "started", "finished",
                                                   "log_sha256", "claim")))
            if phase == "box-precondition":
                specific = (obs.get("identity") == OPERATOR_USER and obs.get("installed_commit")
                            and obs.get("host_id") and obs.get("boot_id")
                            and obs.get("host_id") != "unknown" and obs.get("boot_id") != "unknown"
                            and obs.get("subject") == "active host and installed isolation boundary")
            elif phase == "candidate-isolated":
                specific = (obs.get("identity") == WORKER_USER and obs.get("candidate_commit")
                            and obs.get("runtime_sha256")
                            and obs.get("runtime_sha256_after") == obs.get("runtime_sha256")
                            and obs.get("runtime_interpreter_sha256")
                            and obs.get("runtime_requirements_sha256")
                            and obs.get("subject") == f"candidate commit {obs.get('candidate_commit')}")
            else:
                specific = (obs.get("identity") == OPERATOR_USER and obs.get("candidate_commit")
                            and "data" in obs.get("claim", "")
                            and obs.get("subject") == f"candidate commit {obs.get('candidate_commit')}")
            if common and specific:
                passing.append(obs)
        if not passing:
            statuses = ",".join(str(o.get("status", "NO RESULT")) for o in assigned)
            problems.append(f"{t}: {statuses} in assigned phase {phase} or incomplete provenance")
    if problems:
        return False, "required tests did not pass in their assigned phases: " + "; ".join(problems)
    return True, f"all {len(required)} required tests passed with phase-aware provenance"


def required_tests() -> dict:
    """Which tests MUST have run, and the commit they are pinned to — selected by the ORCHESTRATOR
    from ITS OWN checkout's git tree at HEAD, never from the working directory, so a candidate
    cannot shrink its own required set by deleting test files, AND never from a dirty/untracked
    working tree, so an uncommitted edit/deletion/addition under tests/ cannot silently redefine
    the set either (B4 — the fix for H4). Fails closed (raises ValueError) if the working tree has
    drifted from HEAD for any grader-relevant input; callers must not catch-and-ignore this.

    Deliberately blunt: every test in the installed repo is required. One suite, it is fast, and a
    cleverer selector is exactly the kind of mechanism we are no longer building speculatively
    (R26 — gates are earned by real failures, not imagined ones)."""
    commit = git("rev-parse", "HEAD", cwd=ROOT)
    drift = grader_drift(commit, ROOT)
    if drift:
        raise ValueError(f"grader input drifted from HEAD {commit[:9]}: " + "; ".join(drift))
    policy = execution_policy(ROOT, commit)
    return {"installed_commit": commit, "required": policy["required"]}


def evaluate_binary_review(verdict: str, criteria: list[dict], scope_finding: str,
                           regression_finding: str, security_findings: str) -> str | None:
    """Evaluate only the binary rubric; advisory quality is deliberately not an input."""
    if verdict not in ("PASS", "FAIL"):
        return None
    if not all(isinstance(f, str) and f for f in
               (scope_finding, regression_finding, security_findings)):
        return None
    if verdict == "PASS" and any(c.get("result") != "MET" for c in criteria):
        return None
    return verdict


def write_review_record(att: Path, verdict: "dict | None", effective_reviewer_model: str) -> None:
    """Persist the canonical review.json, binding the EFFECTIVE reviewer model (the one that
    actually produced the verdict) onto the record. This is the SINGLE writer
    of review.json's provenance (round-3 review, finding 2): keeping it here lets a test assert the
    attribution directly, instead of it being an untested side effect of the dispatch pipeline. The
    verdict object is copied, never mutated, so the reviewer's own fields are left untouched; the
    added key is namespaced control-plane provenance that existing key-selecting readers ignore. A
    missing verdict writes an empty record with no bogus attribution."""
    record = dict(verdict) if verdict else None
    if record:
        record["effective_reviewer_model"] = effective_reviewer_model
    atomic_write(att / "review.json", json.dumps(record, indent=2) if record else "{}")


def validate_review_verdict(verdict: dict, schema_obj: dict, lc: dict, wc: str) -> bool:
    """Fail-closed structural, binding, and binary-rubric consistency validation."""
    try:
        Draft202012Validator(schema_obj).validate(verdict)
        expected_version = schema_obj["properties"]["schema_version"]["const"]
    except Exception:
        return False
    if (verdict.get("spec_digest") != lc["spec_digest"]
            or verdict.get("base_sha") != lc["base_sha"]
            or verdict.get("worker_commit") != wc
            or verdict.get("schema_version") != expected_version):
        return False
    return evaluate_binary_review(
        verdict.get("verdict"), verdict.get("criteria", []),
        verdict.get("scope_finding"), verdict.get("regression_finding"),
        verdict.get("security_findings")) is not None


def review(att: Path, spec_id: str, lc: dict, wc: str, test_attestation=None):
    # policy-note item 2: mandatory structured rubric. The worker's plan/checklist is NEVER
    # included here (confirmation-bias contamination) — only spec, diff, and orchestrator evidence.
    wt = Path(lc["worktree"])
    # The frozen model fields are resolved ONCE, up front: the record's own, or the shipped
    # legacy alias map for a genuine pre-R71 record.
    frozen = lc_frozen_model_fields(lc)
    # R73 Job 1: the CLI adapter is selected by the FROZEN reviewer vendor (all-or-none group of
    # its own; pre-freezing records are legally codex-worker/claude-reviewer). Adapter loading
    # failures, unknown vendors, and partial vendor records all yield no verdict — fail closed.
    vendors = lc_frozen_vendor_fields(lc)
    if vendors is None:
        return None, ("launch record carries a partial set of frozen vendor fields "
                      "(corrupt launch.json); fail closed — no reviewer was invoked")
    # R73 round-2 review (blocking): the adapter module is the one PINNED at dispatcher import
    # (VENDOR_ADAPTERS), never re-read from disk here — a mid-attempt installation cannot swap
    # the adapter under a running attempt. Pin failure or an unknown vendor yields no verdict.
    if VENDOR_ADAPTERS is None:
        return None, (f"vendor adapters failed to load at dispatcher start "
                      f"({VENDOR_ADAPTERS_ERR}); fail closed — no reviewer was invoked")
    try:
        adapter = VENDOR_ADAPTERS.get_reviewer_adapter(vendors["reviewer_vendor"])
    except Exception as exc:
        return None, (f"reviewer adapter unavailable for vendor "
                      f"{vendors.get('reviewer_vendor')!r}: {exc}; fail closed — "
                      f"no reviewer was invoked")
    diff = git("diff", f"{lc['base_sha']}..{wc}", cwd=wt)
    schema_obj = _verdict_schema_for_attempt(att)
    # R73 falsifier finding (SPEC-019-1): the codex reviewer transcribed spec_digest with a
    # dropped repeated byte ("…0a0a0b…" → "…0a0b…") and the binding equality check refused the
    # verdict. The echo fields are pinned as const in the schema the reviewer's structured
    # output must satisfy, so a CLI-enforced schema cannot emit a mistyped binding; the
    # validator's own equality checks below are unchanged and still authoritative.
    for _fld, _val in (("spec_digest", lc["spec_digest"]), ("base_sha", lc["base_sha"]),
                       ("worker_commit", wc)):
        if _fld in schema_obj.get("properties", {}):
            schema_obj["properties"][_fld] = {**schema_obj["properties"][_fld], "const": _val}
    schema_version = schema_obj.get("properties", {}).get("schema_version", {}).get("const")
    quality_instructions = ""
    if schema_version == "3":
        # Accepted residual: binary findings and advisory scores come from one reviewer invocation,
        # so anchoring/halo coupling remains possible. A separate scoring pass is deferred because
        # it doubles reviewer quota; score VALUES therefore remain rigorously outside gate inputs.
        quality_instructions = (
            "\n\nAlso fill required `quality` dimensions. Every dimension needs an integer score "
            "1-5 and evidence citing a concrete diff, test, or path reference. Use these behavioral "
            "anchors exactly:\n"
            "maintainability (how safely future engineers can understand/change the implementation, "
            "independent of whether it matches repository architecture): 1=opaque or hazardous to "
            "change; 2=major clarity/coupling debt; 3=ordinary readable code with manageable debt; "
            "4=clear, cohesive, and easy to modify; 5=exceptionally clear with localized change "
            "surfaces and strong defensive structure.\n"
            "design_fit (how well the approach follows existing repository architecture and "
            "conventions, independent of local code readability): 1=contradicts core architecture; "
            "2=significant convention or layering mismatch; 3=compatible with established patterns; "
            "4=well aligned and reuses appropriate abstractions; 5=exemplary architectural fit that "
            "strengthens existing patterns.\n"
            "test_quality (how convincingly tests detect regressions in the changed behavior): "
            "1=missing or effectively vacuous; 2=major behaviors/boundaries untested; 3=core behavior "
            "covered with meaningful assertions; 4=core plus important boundary/failure cases covered; "
            "5=highly discriminating coverage including regressions, boundaries, and failure modes.\n"
            "The PASS/FAIL verdict MUST be decided ONLY by the binary rubric (criteria, scope, "
            "regression, and security). Quality score VALUES are advisory trend signals and MUST "
            "have no influence on PASS/FAIL. The quality block's presence and schema validity are "
            "still mandatory and fail closed."
        )
    req = (
        "You are a code reviewer acting as a hard, fail-closed gate. Review ONE worker change "
        "against ONE spec. Return a verdict only; do not fix anything. There is NO planning "
        "phase.\n\n"
        "Fill the structured rubric: `criteria[]` — one entry per acceptance criterion (in order) "
        "with result MET/UNMET and a concrete evidence reference (path/line/diff/test excerpt); "
        "`scope_finding`; `regression_finding`; `security_findings` (injected secrets, unsafe "
        "shell, credential access, network use). PASS only if EVERY criterion is MET and no "
        "blocking scope/regression/security finding exists; otherwise FAIL. A finding is "
        "blocking only when genuinely critical: it breaks specified behavior, safety, or "
        "security, or ships a real regression. Style, taste, and postponable improvements are "
        "never FAIL grounds — record them in `reasons[]` as 'note:' items for the backlog. If "
        "evidence is missing or ambiguous, FAIL (fail closed). `reasons[]` must be non-empty. You MUST echo "
        "spec_digest, base_sha and worker_commit verbatim; the verdict is void otherwise. "
        f"schema_version is \"{schema_version}\"." + quality_instructions +
        # B2: the SNAPSHOT taken at launch, never the live spec file — an edit to specs/<id>.yaml
        # after approval must not weaken what the reviewer judges the change against. Re-hashed and
        # verified against the recorded digest on this read (B2 finding 1: post-launch tampering
        # with spec-snapshot.yaml is refused, not just its absence).
        "\n\n=== SPEC ===\n" + snapshot_spec_text(
            att, lc.get("spec_snapshot_digest") or lc["spec_digest"]) +
        f"\n\n=== BINDING ===\nspec_digest: {lc['spec_digest']}\nbase_sha: {lc['base_sha']}\n"
        f"worker_commit: {wc}\n\n=== EVIDENCE (from the orchestrator, not the worker) ===\n"
        f"integrity: PASS\nscope: PASS\n"
        # T1 (R26): the reviewer used to be told only "test_command exited 0" — which is how it
        # certified SPEC-015's three SKIPPED tests as proof. It now gets the orchestrator's own
        # per-test attestation. This is control-plane evidence, not worker-authored text.
        "tests (phase-aware; claims are limited to their recorded subject/identity):\n" +
        json.dumps(test_attestation if test_attestation is not None else {"attested": False},
                   indent=2, sort_keys=True) + "\n\n"
        "=== DIFF ===\n" + diff
    )
    # R73 Job 1: the adapter shapes the prompt for its CLI's structured-output mechanism (claude:
    # identity, schema rides in argv; codex: schema text appended, enforced via --output-schema
    # written durably under raw/ — PrivateTmp-safe by construction). The durable review-request
    # is the SHAPED prompt: exactly what the reviewer saw.
    req = adapter.reviewer_prompt(req, schema_obj)
    schema_path = att / "raw" / "review-schema.json"
    schema_path.write_text(json.dumps(schema_obj, indent=2))
    (att / "raw" / "review-request.txt").write_text(req)
    # D5: the reviewer is an LLM process running as the operator, judging WORKER-CONTROLLED diff
    # text — a confused-deputy risk (SOL). It gets the full spec + diff + evidence in the prompt
    # and needs NO host filesystem access. A CLAUDE reviewer has all tools denied; a CODEX
    # reviewer's read-only sandbox limits only model-spawned commands (its own file-read surface
    # is an accepted residual, SECURITY.md). Nothing to inspect beyond what the orchestrator provided.
    # B6 round-2 finding 3: the reviewer LLM call is the one long control-plane phase; cap it at the
    # remaining time to the absolute deadline too (the outer unit's RuntimeMaxSec is the whole-attempt
    # backstop, this bounds the phase itself). None => no time left => fail closed (no verdict).
    dl = lc.get("deadline_ts")

    def invoke_reviewer(model_id):
        # Round-1 review: the timeout prefix is recomputed per invocation, so a fallback run
        # gets only the time genuinely remaining — a primary call that burned the budget before
        # erroring cannot hand the fallback a stale, over-long allowance. Returns a refusal
        # string instead of a CompletedProcess when the phase must not start.
        prefix = deadline_timeout_prefix(dl) if dl is not None else []
        if prefix is None:
            return "attempt deadline exhausted before the review phase (B6); fail closed"
        # R73 Job 1: argv comes from the vendor adapter (claude keeps the exact B16-hardened
        # flag set, verbatim, inside ClaudeReviewer; codex uses --output-schema + read-only
        # sandbox). Aliases come from the frozen launch config; ids without an alias pass
        # through unchanged, and pre-config records keep the shipped alias (round-2 review).
        # Kimi slice 3: the shaped request rides along — kimi has no stdin transport, so its
        # argv carries the prompt itself; claude/codex ignore the keyword and keep reading
        # stdin. A ValueError is the adapter refusing the invocation (kimi: missing request,
        # or a request over the argv byte guard — refused, never truncated) and becomes this
        # phase's refusal string: no reviewer runs, no verdict exists.
        try:
            cmd = [*prefix, *adapter.build_argv(model_id, lc["reviewer_effort"], schema_obj,
                                                frozen["cli_aliases"], schema_path,
                                                request=req)]
        except ValueError as exc:
            return f"reviewer argv refused: {exc}"
        # B16 + reviewer isolation: run from an empty directory OUTSIDE this repo so the reviewer
        # process loads no project rulebook or memory (it must see only spec+diff+evidence, and that
        # context is pure token waste for a tools-denied one-shot). TMPDIR may point inside the repo,
        # so the location is asserted, not assumed (round-2). A nonzero exit is refused before any
        # parse: an errored process's stdout — even schema-valid JSON — is not a verdict.
        with tempfile.TemporaryDirectory(prefix="relay-review-") as neutral_cwd:
            if Path(neutral_cwd).resolve().is_relative_to(ROOT.resolve()):
                return ("reviewer neutral cwd resolves inside the repo "
                        "(TMPDIR misconfiguration); refusing to run the reviewer (B16)")
            return run(cmd, input=req, cwd=neutral_cwd)

    cp = invoke_reviewer(lc["reviewer_model"])
    if isinstance(cp, str):
        return None, cp
    # R94 removed the R69 reviewer-retirement failover (owner closed R69): a retired reviewer
    # model now simply fails the review fail-closed, and the owner flips scripts/models.json.
    # Nothing retries — no error may buy the diff a second reviewer roll.
    (att / "raw" / "review-envelope.json").write_text(cp.stdout or "")
    if cp.returncode != 0:
        return None, cp.stdout
    # R73 Job 1: verdict extraction is the adapter's (claude: envelope double-parse; codex: bare
    # JSON with a fence-strip fallback). None ⇒ no verdict; validate_review_verdict stays the
    # vendor-neutral gate that actually binds the verdict to this exact code.
    verdict = adapter.extract_verdict(cp.stdout or "")
    if verdict is None:
        return None, cp.stdout
    if not validate_review_verdict(verdict, schema_obj, lc, wc):
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
        f"| worker | `{lc['worker_model']}` (reasoning={lc['worker_effort']}), "
        + ("subagent BUILD in the orchestrator trust domain (SECURITY.md)"
           if lc.get("worker_mode") == "subagent" else
           "sandbox=workspace-write (build phase is networked, see SECURITY.md)")
        # Round-2 major 2: the test-phase network claim must match the FROZEN isolation
        # decision — under break-glass (isolation:false, exposure recorded) the spec test runs
        # as the operator with no private-network service, and provenance must say so.
        + (", network=off for tests" if lc.get("isolation") else
           ", tests ran UNISOLATED as the operator (break-glass, recorded in launch.json)")
        + " |\n"
        f"| reviewer | `{lc['reviewer_model']}` → PASS (bound) |\n\n"
        f"Integrity/scope/test/review all PASS. Provenance under "
        f"`.orchestrator/attempts/{spec_id}/{lc['attempt']}/`. Draft: CI + branch protection are "
        f"the hard gate; the operator merges (D9/D12). Commit authored by the worker, packaged by the "
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
def cmd_await(attempt_id: str, interval: int = 5, max_wait: int = 8 * 3600,
              show_stderr: bool = False) -> None:
    spec_id, n = parse_attempt_id(attempt_id)
    unit = unit_name(spec_id, n)
    waited = 0
    while waited < max_wait:
        st = read_state(spec_id) or {}
        status = st.get("status") if st.get("attempt_id") == attempt_id else None
        if status in TERMINAL:
            # Surface the WHY and the evidence path, not just the class — an opaque error_class
            # sent an operator around five blind relaunches (dev-box feedback, R51).
            att = ATTEMPTS / spec_id / str(n)
            out = {"attempt_id": attempt_id, "status": status,
                   "error_class": st.get("error_class"), "detail": st.get("detail"),
                   "evidence": str(att)}
            try:  # result.json carries the full record; state may hold only a summary
                r = json.loads((att / "result.json").read_text())
                out["detail"] = r.get("detail", out["detail"])
                if "worker_exit" in r:
                    out["worker_exit"] = r["worker_exit"]
            except Exception:
                pass
            if show_stderr and status in ("failed_worker_error", "interrupted"):
                # OPT-IN local display only (round-2 review: stdout reaches automation logs too).
                # raw/ is gitignored; this never enters provenance.
                try:
                    tail = (att / "raw" / "worker-stderr.txt").read_text()[-800:].strip()
                    if tail:
                        out["stderr_tail_local"] = tail
                except OSError:
                    pass
            print(json.dumps(out))
            sys.exit(0 if status == "passed_pr_opened" else 1)
        # R73 Job 3: awaiting_build has no unit BY DESIGN — the BUILD is running inside the
        # orchestrator session. Await is for attempts with a pipeline unit; say so and leave
        # (exit 3: neither success nor a terminal failure), instead of eight silent hours or a
        # false 'interrupted' from the unit check below.
        if status == "awaiting_build":
            print(json.dumps({"attempt_id": attempt_id, "status": "awaiting_build",
                              "detail": "subagent BUILD pending in the orchestrator session; "
                                        "run `dispatch continue` after the BUILD, then await"}))
            sys.exit(3)
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
def attempt_units_remaining(attempt_id: str, outer_unit: str | None = None) -> tuple[list[str], bool]:
    """B6 verification: after teardown, no true SLICE MEMBER (worker/test/regression SYSTEM service)
    for this attempt should remain. Returns (offending unit names, query_ok). query_ok is False if
    the underlying list-units query FAILED on either manager — a failed query is never read as
    'nothing remains' (fail closed, round-1 review).

    Round-2 finding 1: when this runs inside the outer unit's OWN ExecStopPost (the timeout path),
    that outer --user pipeline unit is still 'deactivating' and list-units reports it — it is NOT a
    leaked slice member, so exclude it (and the slice CONTAINER unit itself, which empties on stop).
    Otherwise every hook invocation would falsely read verified=False and escalate."""
    units, query_ok = _list_codex_units()
    excluded = {attempt_slice(attempt_id)}                 # codex-<aid>.slice — a container, not work
    if outer_unit:
        excluded.add(outer_unit)                           # codex-<aid>  (defensive, if unsuffixed)
        excluded.add(f"{outer_unit}.service")              # codex-<aid>.service as list-units prints it
    return [u for u in units if attempt_id in u and u not in excluded], query_ok


def teardown_attempt(attempt_id: str, outer_unit: str | None, *, stop_outer: bool = True) -> dict:
    """B6 unified teardown for cancel / confirmed-hang / timeout / reconcile — every path that ends
    an attempt uses THIS, so none can regress to stopping two hand-picked unit names.

    ORDER (round-1 review, finding 2 — no race with the producer): stop the PRODUCER (the outer
    --user pipeline unit) FIRST so `_run` can no longer spawn a new slice member — otherwise a killed
    regbase run read as the expected base failure would immediately launch regcand, and the
    installed-test loop could likewise advance, INTO a torn-down slice. Only THEN stop the slice, and
    stop it ONCE MORE afterwards to reap anything `_run` spawned during its own SIGTERM window.
    (stop_outer=False is for the in-unit timeout path, where systemd is already stopping the producer
    — us — so we must not, and cannot usefully, stop it again; the ordering still holds.)

    VERIFY (round-1 review, finding 3 — fail closed): teardown is 'verified' ONLY when the post-stop
    query SUCCEEDED on both managers AND no unit for the attempt remains. A failed/errored query
    yields verified=False, never a false 'all clear'.

    VERIFY (round-3 review, finding 1 — the outer-stop rc gates verification): attempt_units_remaining
    EXCLUDES the outer unit, which is correct ONLY because the outer unit is either deactivating (the
    ExecStopPost/timeout path) or we JUST stopped it (cancel/health/reconcile). But if that
    `systemctl --user stop` of the outer unit FAILED, the outer unit may still be ALIVE and able to
    spawn slice members, yet we excluded it — so we would falsely verify. Therefore, whenever we
    stopped the outer unit ourselves (stop_outer=True), verification ALSO requires outer_stop_rc == 0.
    On the timeout path (stop_outer=False) systemd owns the outer unit's teardown, so the exclusion
    stands and the rc does not gate."""
    slice_name = attempt_slice(attempt_id)
    outer_stop_rc = None
    if stop_outer and outer_unit:
        outer_stop_rc = run(["systemctl", "--user", "stop", outer_unit]).returncode
    slice_stop_rc = run(["sudo", "-n", "systemctl", "stop", slice_name]).returncode
    if stop_outer and outer_unit:
        # producer is quiesced now; a second slice stop reaps any member it launched mid-teardown
        slice_stop_rc = run(["sudo", "-n", "systemctl", "stop", slice_name]).returncode
    # Exclude the outer unit from the remaining set: on the timeout path it is deactivating (us), and
    # on cancel/health we have just stopped it — either way it is not a leaked slice member (finding 1).
    remaining, query_ok = attempt_units_remaining(attempt_id, outer_unit)
    verified = query_ok and not remaining
    if stop_outer and outer_unit:
        # round-3 finding 1: a failed outer stop invalidates the exclusion above — fail closed.
        verified = verified and outer_stop_rc == 0
    return {"slice": slice_name, "outer_stop_rc": outer_stop_rc, "slice_stop_rc": slice_stop_rc,
            "remaining_units": remaining, "query_ok": query_ok, "verified": verified}


def _teardown_detail(td: dict) -> str:
    """A human reason appended to terminal state when teardown could not be VERIFIED clean."""
    if td["remaining_units"]:
        return f"; ESCALATED: units still present after teardown: {td['remaining_units']}"
    if not td["query_ok"]:
        return "; ESCALATED: could not verify teardown (systemctl list-units query failed) — fail closed"
    if td.get("outer_stop_rc") not in (None, 0):
        # round-3 finding 1: the outer unit's stop failed, so it may still be alive (and able to spawn
        # slice members) even though it was excluded from the remaining set — fail closed.
        return (f"; ESCALATED: outer unit stop failed (rc={td['outer_stop_rc']}); it may still be "
                "running and able to spawn members — teardown NOT verified")
    return ""


def cmd_cancel(attempt_id: str) -> None:
    spec_id, n = parse_attempt_id(attempt_id)
    unit = unit_name(spec_id, n)
    # Label FIRST, before stopping the outer unit: the outer unit's ExecStopPost=`timeout` hook fires
    # synchronously DURING that stop, so if the state were still LIVE it would relabel this operator
    # cancel as a timeout. Writing the terminal label now makes cmd_timeout a teardown-only no-op.
    # R73 Job 3 (round-1 blocking 1+2): read-verify-label under the ONE state lock — `dispatch
    # continue` holds the same lock across its awaiting_build->running claim AND its unit start,
    # so the status we label from cannot be half a claim: either we flip awaiting_build terminal
    # first (continue then refuses; no unit ever existed — skip the outer-unit stop so the
    # teardown verifies clean) or continue won (we see 'running' and tear down normally).
    was_awaiting = False
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            st = read_state(spec_id) or {}
            if st.get("attempt_id") == attempt_id and st.get("status") in LIVE:
                was_awaiting = st.get("status") == "awaiting_build"
                atomic_write(STATE / f"{spec_id}.json",
                             json.dumps({**st, "status": "interrupted",
                                         "error_class": "cancelled",
                                         "detail": "cancelled by operator",
                                         "updated": now()}, indent=2))
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)
    # B6: producer first, then slice, then verify. An awaiting_build attempt HAS no producer
    # unit by design — stopping the nonexistent unit would read as an unverifiable teardown
    # (round-3 rule: a failed outer stop gates verification), so the ordinary cancellation of a
    # pending BUILD skips the outer stop; the slice sweep + fail-closed query still run.
    td = teardown_attempt(attempt_id, unit, stop_outer=not was_awaiting)
    if not td["verified"]:
        # finding 3: a failed query or a surviving unit is escalated + a nonzero exit — never a
        # warn-and-continue that reads as success.
        cur = read_state(spec_id) or {}
        if cur.get("attempt_id") == attempt_id:
            write_state(spec_id, {**cur, "detail": (cur.get("detail", "") + _teardown_detail(td))})
        escalate(spec_id, "cancel teardown could not be verified clean (B6)",
                 {"attempt_id": attempt_id, **td})
    print(json.dumps({"attempt_id": attempt_id, "unit": unit,
                      "outer_stop_rc": td["outer_stop_rc"], "slice_stop_rc": td["slice_stop_rc"],
                      "remaining_units": td["remaining_units"], "verified": td["verified"]}))
    sys.exit(0 if td["verified"] else 1)


# ============================================================== timeout =======
def cmd_timeout(attempt_id: str) -> None:
    """B6 finding 4: when the outer unit's own RuntimeMaxSec fires (or it is otherwise stopped), the
    attempt's SYSTEM units are independent and would linger until a later reconcile. The outer unit
    carries `ExecStopPost=dispatch timeout <attempt_id>`, so THIS runs at stop time and performs the
    SAME teardown + verification as cancel — no deferral. Idempotent and state-safe: it writes a
    terminal timeout record ONLY when the attempt is still LIVE, so it never clobbers a normal
    terminal state (`finish` already ran) or an operator cancel.

    It runs as an ExecStopPost of the dying outer unit, so systemd is already stopping the producer:
    stop_outer=False (we must not try to stop ourselves), the ordering guarantee still holds. The
    outer unit name is still passed so verification EXCLUDES this deactivating unit itself (round-2
    finding 1)."""
    spec_id, n = parse_attempt_id(attempt_id)
    unit = unit_name(spec_id, n)
    td = teardown_attempt(attempt_id, unit, stop_outer=False)
    st = read_state(spec_id) or {}
    if st.get("attempt_id") == attempt_id and st.get("status") in LIVE:
        write_state(spec_id, {**st, "status": "interrupted", "error_class": ERR_TIMEOUT,
                              "detail": "attempt outer unit stopped (hard ceiling / RuntimeMaxSec "
                                        "or external stop); slice torn down" + _teardown_detail(td)})
    # finding 2: a failed verification is escalated + a nonzero exit on EVERY hook invocation, not
    # only when the state was LIVE — a leaked member during a normal-finish/cancel cleanup is still a
    # durable incident. (With finding 1, a clean teardown verifies true, so no false escalation.)
    if not td["verified"]:
        escalate(spec_id, "timeout teardown could not be verified clean (B6)",
                 {"attempt_id": attempt_id, **td})
    print(json.dumps({"attempt_id": attempt_id, "verified": td["verified"],
                      "remaining_units": td["remaining_units"],
                      "state_was_live": st.get("status") in LIVE}))
    sys.exit(0 if td["verified"] else 1)


# =============================================================== health =======
# Gate 3 health monitoring: soft-alert, confirm-then-cancel. Silence on the JSONL event stream is
# NOT death — a long compile/test is silent but busy. We only cancel a CONFIRMED hang: unit alive
# but no CPU progress AND no new events AND no journal activity across TWO consecutive checks.
HEALTH_INACTIVITY_MIN = 10          # configurable; a stale event stream past this raises an alert
HEALTH_CPU_EPSILON_NS = 50_000_000  # 50ms of CPU between checks counts as "made progress"


def _health_snap_path(spec_id: str) -> Path:
    return STATE / f"{spec_id}.health.json"


def _read_health_snap(spec_id: str) -> dict:
    p = _health_snap_path(spec_id)
    return json.loads(p.read_text()) if p.exists() else {}


def _journal_lines_since(unit: str, since_ts: float) -> int:
    if since_ts <= 0:
        return 0
    cp = run(["journalctl", "--user", "-u", unit, "--since",
              datetime.fromtimestamp(since_ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
              "-o", "cat", "--no-pager"])
    return len([ln for ln in (cp.stdout or "").splitlines() if ln.strip()])


def cmd_health(attempt_id: str, inactivity_min: int = HEALTH_INACTIVITY_MIN) -> None:
    spec_id, n = parse_attempt_id(attempt_id)
    unit = unit_name(spec_id, n)
    att = ATTEMPTS / spec_id / str(n)
    events = att / "raw" / "events.jsonl"

    # R73 Job 3: no unit, no event stream to judge — health for a pending subagent BUILD is the
    # deadline story reconcile owns; say so instead of reading a dead unit as inactivity.
    st0 = read_state(spec_id) or {}
    if st0.get("attempt_id") == attempt_id and st0.get("status") == "awaiting_build":
        print(json.dumps({"attempt_id": attempt_id, "status": "awaiting_build",
                          "health": "not-applicable",
                          "detail": "subagent BUILD pending in the orchestrator session; "
                                    "reconcile expires it at the frozen deadline"}))
        return

    show = systemctl_show(unit, "ActiveState", "SubState", "CPUUsageNSec")
    active = show.get("ActiveState") in {"active", "activating"}
    cpu = int(show.get("CPUUsageNSec", "0") or 0)
    nowts = time.time()
    ev_mtime = events.stat().st_mtime if events.exists() else 0.0
    ev_lines = sum(1 for _ in events.open()) if events.exists() else 0
    idle_s = nowts - ev_mtime if ev_mtime else 1e9

    snap = _read_health_snap(spec_id)
    same_attempt = snap.get("attempt_id") == attempt_id
    prior_dead = snap.get("consecutive_dead", 0) if same_attempt else 0

    out = {"attempt_id": attempt_id, "unit": unit, "active_state": show.get("ActiveState", "gone"),
           "idle_seconds": round(idle_s), "event_lines": ev_lines, "cpu_nsec": cpu}

    action = "none"
    teardown_failed = False
    if not active:
        health = "unit_inactive"          # terminal/gone — status/await handle it, not a hang
        consecutive_dead = 0
    elif idle_s < inactivity_min * 60:
        health = "healthy"                # recent event → alive
        consecutive_dead = 0
    else:
        # Stale event stream — ALERT. Inspect deeper before any kill.
        cpu_delta = cpu - snap.get("cpu_nsec", cpu) if same_attempt else 0
        events_grew = ev_lines > snap.get("event_lines", ev_lines) if same_attempt else False
        journal_new = _journal_lines_since(unit, snap.get("checked_ts", 0)) if same_attempt else 0
        progressing = cpu_delta > HEALTH_CPU_EPSILON_NS or events_grew or journal_new > 0
        out.update({"cpu_delta_nsec": cpu_delta, "events_grew": events_grew,
                    "journal_new_lines": journal_new})
        if progressing:
            health = "busy_no_events"     # silent but working (e.g. long compile) — DO NOT KILL
            consecutive_dead = 0
        else:
            consecutive_dead = prior_dead + 1
            if consecutive_dead >= 2:
                health = "confirmed_hang"  # two consecutive dead checks → cancel
                action = "cancelled"
                # Label FIRST (see cmd_cancel): the outer unit's ExecStopPost=`timeout` hook fires
                # during teardown's outer-unit stop and must see a terminal state, not relabel.
                st = read_state(spec_id) or {}
                labelled = st.get("attempt_id") == attempt_id and st.get("status") in LIVE
                if labelled:
                    write_state(spec_id, {**st, "status": "interrupted", "error_class": "hang",
                                          "detail": "confirmed hang: no CPU/event/journal progress "
                                                    "across two consecutive health checks"})
                td = teardown_attempt(attempt_id, unit)   # B6: producer first, then slice, then verify
                out["remaining_units"] = td["remaining_units"]
                out["teardown_verified"] = td["verified"]
                teardown_failed = not td["verified"]
                if teardown_failed:
                    # finding 2: escalate + exit nonzero on ANY verification failure, not only when we
                    # wrote the label — a leaked member is a durable incident regardless.
                    if labelled:
                        cur = read_state(spec_id) or {}
                        if cur.get("attempt_id") == attempt_id:
                            write_state(spec_id, {**cur,
                                                  "detail": (cur.get("detail", "") + _teardown_detail(td))})
                    escalate(spec_id, "confirmed-hang teardown could not be verified clean (B6)",
                             {"attempt_id": attempt_id, **td})
            else:
                health = "alert_pending_confirm"  # first dead check — wait for a second to confirm

    out["health"] = health
    out["consecutive_dead"] = consecutive_dead
    out["action"] = action
    atomic_write(_health_snap_path(spec_id), json.dumps({
        "attempt_id": attempt_id, "checked_ts": nowts, "cpu_nsec": cpu,
        "event_lines": ev_lines, "consecutive_dead": consecutive_dead,
    }, indent=2))
    print(json.dumps(out, indent=2))
    # finding 2: a confirmed-hang teardown that could not be verified clean exits nonzero (fail
    # closed) so an automated health loop cannot read the kill as success. A clean check returns 0.
    if teardown_failed:
        sys.exit(1)


# ============================================================= reconcile ======
def _locked_relabel(spec_id: str, snapshot: dict, new_fields: dict, recheck=None) -> bool:
    """Reconcile's terminal relabel as a locked CAS (R73 Job 3 round-2 blocking 1): re-read the
    canonical state under the ONE state lock, confirm it is still exactly the lifecycle situation
    the unlocked scan diagnosed (same attempt, same status), run any extra in-lock recheck (e.g.
    the unit is STILL gone), and only then write. `dispatch continue` holds this same lock across
    its claim-and-unit-start and cancel labels under it — so a reconcile relabel can no longer
    land on top of a claim or a cancellation it never saw; it skips and reports instead."""
    STATE.mkdir(parents=True, exist_ok=True)
    with open(STATE / ".lock", "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            cur = read_state(spec_id) or {}
            if (cur.get("attempt_id") != snapshot.get("attempt_id")
                    or cur.get("status") != snapshot.get("status")):
                return False
            if recheck is not None and not recheck():
                return False
            # Fields may be computed FROM the in-lock state (round-3 blocking 1: a detail
            # append must concatenate onto what is canonical NOW, not a pre-lock capture).
            fields = new_fields(cur) if callable(new_fields) else new_fields
            atomic_write(STATE / f"{spec_id}.json",
                         json.dumps({**cur, **fields, "updated": now()}, indent=2))
            return True
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def cmd_reconcile() -> None:
    """Session-start ritual (Gate 3 / CLAUDE.md): read state, inspect real units, mark drift.

    B6: the outer --user pipeline unit dying (crash, box restart, OR its own RuntimeMaxSec timeout)
    does NOT stop the attempt's SYSTEM units (worker/test/regression) — they are independent units
    in their own slice. So whenever reconcile finds the outer unit gone while state was still LIVE,
    it also stops the attempt slice and verifies nothing was left running, instead of just relabeling
    state and leaving orphans."""
    reconciled = []
    any_unverified = False
    for st in all_states():
        if st.get("status") not in LIVE:
            continue
        aid = st.get("attempt_id")
        spec_id = st.get("spec_id")
        # R73 Job 3: awaiting_build is LIVE-without-a-unit by design (subagent BUILD inside the
        # orchestrator session), so 'unit gone' is not a crash signal for it. It expires at the
        # launch-frozen absolute deadline (B6) instead; an unreadable/missing deadline is corrupt
        # state and expires too (fail closed, never an immortal claim on a concurrency slot).
        if st.get("status") == "awaiting_build":
            try:
                lc = json.loads((ATTEMPTS / spec_id / str(st.get("attempt")) /
                                 "launch.json").read_text())
                expired = time.time() > float(lc["deadline_ts"])
                why = "attempt deadline exhausted during the subagent BUILD (B6)"
            except Exception as e:
                expired, why = True, f"launch record unreadable for awaiting_build state ({e})"
            if expired:
                # Locked CAS (round-2 blocking 1): a cancel or continue that got the lock first
                # already changed the status; skip and report rather than overwrite it.
                if _locked_relabel(spec_id, st,
                                   {"status": "error_timeout", "error_class": ERR_TIMEOUT,
                                    "detail": f"reconcile: {why}; resumable as a fresh attempt"}):
                    reconciled.append({"attempt_id": aid, "from": "awaiting_build",
                                       "to": "error_timeout", "unit_active": False,
                                       "remaining_units": [], "teardown_verified": True})
                else:
                    reconciled.append({"attempt_id": aid, "status": "awaiting_build",
                                       "note": "state changed mid-reconcile (another lifecycle "
                                               "operation owns this attempt); skipped"})
            else:
                reconciled.append({"attempt_id": aid, "status": "awaiting_build",
                                   "unit_active": False,
                                   "note": "subagent BUILD pending (no unit by design); "
                                           "grade with `dispatch continue`"})
            continue
        unit = st.get("unit") or (unit_name(*parse_attempt_id(aid)) if aid else None)
        active = unit_active(unit) if unit else False
        if not active:
            # Locked CAS BEFORE any teardown or relabel (round-2 blocking 1): re-read the state
            # and RE-CHECK the unit under the same lock `dispatch continue` holds across its
            # claim-and-unit-start — a claim whose unit became visible after our unlocked scan
            # is a live attempt, not a crash; skip it. Only a confirmed still-gone unit on the
            # still-identical state is relabeled, and only then is the slice torn down (the
            # terminal label makes any racing lifecycle operation refuse from here).
            def _still_gone():
                return not (unit_active(unit) if unit else False)
            if not _locked_relabel(
                    spec_id, st,
                    {"status": "interrupted", "error_class": "interrupted",
                     "detail": "reconcile: state was LIVE but unit is gone (orchestrator/box "
                               "restart or attempt deadline); resumable as a fresh attempt"},
                    recheck=_still_gone):
                reconciled.append({"attempt_id": aid, "status": st.get("status"),
                                   "note": "state or unit changed mid-reconcile (another "
                                           "lifecycle operation owns this attempt); skipped"})
                continue
            td = {"remaining_units": [], "verified": True, "query_ok": True}
            if aid:
                # Full teardown, not a bare slice stop: producer-first (a no-op if truly gone),
                # then slice, then verify fail-closed — same path as cancel/timeout (B6).
                td = teardown_attempt(aid, unit)
            # The detail append is ITSELF a locked CAS (round-3 blocking 1): it lands only if
            # the canonical state is still OUR interrupted relabel of THIS attempt — a fresh
            # attempt that claimed the spec meanwhile (new attempt_id, 'launching') is left
            # untouched. The appended text concatenates onto the in-lock detail, never onto a
            # pre-lock capture; an empty teardown note writes nothing at all.
            if _teardown_detail(td):
                _locked_relabel(spec_id, {"attempt_id": aid, "status": "interrupted"},
                                lambda cur: {"detail": (cur.get("detail", "")
                                                        + _teardown_detail(td))})
            if aid and not td["verified"]:
                escalate(spec_id, "reconcile teardown could not be verified clean (B6)",
                         {"attempt_id": aid, **td})
                any_unverified = True
            reconciled.append({"attempt_id": aid, "from": st.get("status"),
                               "to": "interrupted", "unit_active": False,
                               "remaining_units": td["remaining_units"],
                               "teardown_verified": td["verified"]})
        else:
            reconciled.append({"attempt_id": aid, "status": st.get("status"),
                               "unit_active": True, "note": "still running"})
    live_units, query_ok = _list_codex_units()
    # B10 round-2: claim_slot refuses to launch over malformed canonical state and points here —
    # so reconcile must SURFACE those files (all_states silently skips them). Report-only: the
    # operator decides whether a corrupt file was a live attempt before removing it.
    malformed = []
    if STATE.exists():
        for p in STATE.glob("*.json"):
            if p.name.endswith(".health.json"):
                continue
            try:
                if not isinstance(json.loads(p.read_text()), dict):
                    malformed.append({"file": str(p), "error": "non-object JSON value"})
            except Exception as e:
                malformed.append({"file": str(p), "error": str(e)})
    print(json.dumps({"reconciled": reconciled, "live_units": live_units,
                      "live_units_query_ok": query_ok, "malformed_state": malformed},
                     indent=2))
    # round-2 finding 2: a teardown that could not be verified clean OR a failed final live-units
    # query exits nonzero (fail closed) — reconcile must not return 0 while an orphan may still run.
    if not query_ok:
        # round-3 finding 4: a failed final query gets a durable escalation too, matching every other
        # fail-closed path (per-attempt teardown failures already escalate inside the loop above).
        escalate("reconcile", "reconcile final live-units query failed — cannot confirm no orphaned "
                              "attempt units remain (B6, fail closed)",
                 {"live_units": live_units, "live_units_query_ok": False})
    if any_unverified or not query_ok:
        sys.exit(1)


def _list_codex_units() -> tuple[list[str], bool]:
    """Returns (codex-owned transient units across BOTH systemd managers, query_ok). B6: the outer
    per-attempt pipeline unit lives in the --user manager; the worker/test/regression units
    isolated_run spawns live in the SYSTEM manager (their own slice/cgroups) — a --user-only listing
    was blind to them, which is exactly how orphaned units went unnoticed. query_ok is False if the
    list-units query FAILED on either manager, so a failed query is never mistaken for 'no units
    remain' (fail closed, round-1 review, finding 3)."""
    user_cp = run(["systemctl", "--user", "list-units", "codex-*", "--no-legend", "--plain"])
    sys_cp = run(["sudo", "-n", "systemctl", "list-units", "codex-*", "--no-legend", "--plain"])
    query_ok = user_cp.returncode == 0 and sys_cp.returncode == 0
    units = [ln.split()[0] for cp in (user_cp, sys_cp)
             for ln in (cp.stdout or "").splitlines() if ln.strip()]
    return units, query_ok


# ================================================================= merge =======
# Plan-scoped autonomy (Level 1.5, ratified by the operator 2026-07-13). The orchestrator may merge an
# attempt's PR to `ready-for-main` WITHOUT a per-PR human click — but ONLY through this fail-closed
# path, and ONLY while the AUTONOMY grant is present. Every correctness gate still applies, plus the
# merge-time base-check that closes the post-PR stale-base hole (SOL, G4-A): after a sibling PR
# integrates, a still-open parallel PR's reviewer verdict is bound to an obsolete base, and CI alone
# does not repair that — so a moved base is refused here and the attempt is re-run fresh. `main`
# promotion is NEVER done here (main stays human-only). Revoke autonomy by deleting AUTONOMY.json.
AUTONOMY = ORCH / "AUTONOMY.json"                 # tracked: ships DISABLED (safe default)
AUTONOMY_LOCAL = ORCH / "AUTONOMY.local.json"     # gitignored: the operator's real grant, if any


def load_autonomy() -> dict | None:
    """Safe by default (SOL, SHARE decision): the tracked AUTONOMY.json ships disabled, so a clone/
    template is NOT autonomous. An operator opts in by creating the gitignored AUTONOMY.local.json,
    which — being untracked — never travels with the repo. Local override wins if present."""
    src = AUTONOMY_LOCAL if AUTONOMY_LOCAL.exists() else AUTONOMY
    if not src.exists():
        return None
    try:
        g = json.loads(src.read_text())
    except Exception:
        return None
    return g if g.get("enabled") is True else None


def _base_tip(base_branch: str) -> str:
    git("fetch", "--quiet", "origin", base_branch)
    return git("rev-parse", f"origin/{base_branch}")


def _pr_number(pr_url: str) -> str:
    return (pr_url or "").rstrip("/").split("/")[-1]


def _ci_conclusion(pr: str) -> str:
    """Definitive result of the required `ci` check on PR, matched by EXACT check name via
    structured JSON — never a substring scan of `gh pr checks` human output (that once merged on an
    'expected'/empty rollup, and would merge on a stray 'pass' anywhere in the text; B7). Returns:
      'SUCCESS'  ci concluded success
      'FAILURE'  ci reached a terminal non-success (failure/error/cancelled/timed_out/...)
      'PENDING'  ci exists but has not concluded, OR the query itself failed — NEVER merge on this
      'MISSING'  no check named ci is present yet
    Fail-closed: anything other than an explicit ci=SUCCESS is non-mergeable."""
    pv = run(["gh", "pr", "view", str(pr), "--json", "statusCheckRollup"])
    if pv.returncode != 0:
        return "PENDING"                       # transient gh/API error: not-yet-definitive, not fail
    try:
        rollup = (json.loads(pv.stdout or "{}") or {}).get("statusCheckRollup") or []
    except Exception:
        return "PENDING"
    ci = [c for c in rollup if c.get("name") == "ci" or c.get("context") == "ci"]
    if not ci:
        return "MISSING"
    result = "SUCCESS"
    for c in ci:
        concl = (c.get("conclusion") or "").upper()        # CheckRun terminal outcome
        state = (c.get("state") or "").upper()             # StatusContext outcome
        if concl == "SUCCESS" or state == "SUCCESS":
            continue
        if state in ("FAILURE", "ERROR") or concl in (
                "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"):
            return "FAILURE"                   # any terminal non-success stops the merge outright
        result = "PENDING"                     # QUEUED/IN_PROGRESS/PENDING/EXPECTED/empty: keep waiting
    return result


def _await_ci_success(prn: str, tries: int = 30, sleep_s: int = 10) -> str:
    """Poll until the required `ci` check is definitively SUCCESS or FAILURE (or tries run out).
    Returns the final conclusion; the caller merges only on 'SUCCESS'."""
    concl = "PENDING"
    for _ in range(tries):
        concl = _ci_conclusion(prn)
        if concl in ("SUCCESS", "FAILURE"):
            return concl
        time.sleep(sleep_s)
    return concl                               # PENDING/MISSING after timeout — caller refuses


def _provenance_merge(prn: str) -> None:
    """Gate the provenance-PR merge on an exact-name ci=SUCCESS. Fail-closed: any non-success state
    leaves the PR open and unmerged rather than leaning on branch protection to reject it (B7)."""
    concl = _await_ci_success(prn)
    if concl != "SUCCESS":
        die(f"provenance PR #{prn}: required 'ci' not green (state={concl}); left OPEN for review, "
            f"not merged.", 20)
    mg = run(["gh", "pr", "merge", str(prn), "--merge", "--delete-branch"])
    if mg.returncode != 0:
        die(f"provenance PR #{prn} merge failed (left open for review): {mg.stderr.strip()}", 20)


def cmd_merge(attempt_id: str) -> None:
    """Auto-merge a PASSED attempt's PR to ready-for-main under the AUTONOMY grant. Fail-closed:
    every check must pass or it refuses without merging. Structured exit codes for the caller."""
    grant = load_autonomy()
    if grant is None:
        die("autonomy not granted (.orchestrator/AUTONOMY.json absent or enabled!=true); "
            "PR merge stays human (Level 1).", 12)
    if HALT.exists():
        die(f"HALT present ({HALT}); refusing to merge.", 3)

    spec_id, n = parse_attempt_id(attempt_id)
    att = ATTEMPTS / spec_id / str(n)
    rp = att / "result.json"
    if not rp.exists():
        die(f"no result.json for {attempt_id}; nothing to merge.", 13)
    result = json.loads(rp.read_text())
    if result.get("status") != "passed_pr_opened":
        die(f"{attempt_id} status is {result.get('status')}, not passed_pr_opened; refuse.", 13)

    lc = json.loads((att / "launch.json").read_text())
    base_branch = lc.get("base_branch", AUTOMATION_BASE)
    # Base pin, defense in depth (B3): never merge a persisted attempt whose base is not the
    # automation target, even if it somehow reached passed_pr_opened.
    if base_branch != AUTOMATION_BASE:
        die(f"attempt base_branch={base_branch!r} is not the automation target {AUTOMATION_BASE!r}; "
            f"refuse to merge (stale/foreign attempt state).", 14)
    base_sha = result.get("base_sha") or lc.get("base_sha")
    worker_commit = result.get("worker_commit")
    pr_url = result.get("pr_url")
    pr = _pr_number(pr_url)

    # Grant bounds (defense in depth; already enforced at launch, re-checked at the merge boundary).
    if base_branch == "main":
        die("main promotion is human-only; never auto-merged.", 12)
    if base_branch != grant.get("target_branch", "ready-for-main"):
        die(f"target branch {base_branch} != grant target; refuse.", 12)

    # B2: refuse the merge if the live spec has drifted from the digest this attempt was approved,
    # built, and reviewed against — a post-approval edit (e.g. downgrading risk_class to slip under
    # this very grant, or weakening acceptance criteria) must never ride an old approval to a merge.
    # spec_digest has been recorded in launch.json since before this fix, so this check applies to
    # every attempt, historical or not.
    approved_digest = lc.get("spec_snapshot_digest") or lc.get("spec_digest")
    if not approved_digest:
        die(f"launch.json for {attempt_id} has no recorded spec digest; refuse to merge.", 12)

    # Read the LIVE spec's bytes exactly ONCE, hash those bytes, and refuse if they drifted from the
    # approved digest. The parse below reuses this same buffer — never a second read (B2 finding 3
    # TOCTOU: hashing one read then load_spec()'ing a second let an edit slip in between).
    try:
        live_bytes = spec_path(spec_id).read_bytes()
    except OSError as e:
        die(f"spec file for {spec_id} unreadable at merge time ({e}); refuse to merge.", 12)
    live_digest = hashlib.sha256(live_bytes).hexdigest()
    if live_digest != approved_digest:
        die(f"spec {spec_id} was edited after approval (approved/snapshot digest "
            f"{approved_digest[:12]}…, live digest {live_digest[:12]}…); refuse to merge "
            f"— re-approve the current spec and relaunch a fresh attempt.", 12)

    # risk_class/needs_network: derived from VERIFIED bytes at the point of use — never from the
    # unverified recorded launch.json fields (B2 finding 2/3). Whether this is a snapshot-format
    # attempt is decided by the LAUNCH MARKER (spec_snapshot_digest present), NOT by the snapshot
    # file merely existing: deleting a new-format attempt's snapshot must fail closed, never fall
    # back to the live file (B2 round-2 finding 2). Only genuinely pre-fix attempts — those whose
    # launch record has no snapshot marker at all — parse the live bytes verified just above (the
    # SAME buffer, not a second read).
    if "spec_snapshot_digest" in lc:
        snap = spec_snapshot_path(att)
        if not snap.exists():
            die(f"attempt {attempt_id} is snapshot-format (spec_snapshot_digest recorded) but its "
                f"spec snapshot {snap} is missing; refuse to merge (no fall-back to the live spec).",
                12)
        _snap_bytes, gate_spec = verify_spec_bytes(
            snap, approved_digest, f"spec snapshot for {attempt_id}", 12)
    else:
        try:
            gate_spec = yaml.safe_load(live_bytes)
        except yaml.YAMLError as e:
            die(f"live spec for {spec_id} YAML parse error at merge time: {e}; refuse.", 12)
        if not isinstance(gate_spec, dict):
            die(f"live spec for {spec_id} is not a mapping; refuse.", 12)

    risk_class = gate_spec.get("risk_class", "default")
    needs_network = gate_spec.get("needs_network", False)
    if risk_class not in grant.get("allowed_risk_class", ["low"]):
        die(f"risk_class {risk_class} not in grant; refuse.", 12)
    if needs_network and not grant.get("needs_network_allowed", False):
        die("needs_network spec not permitted by grant; refuse.", 12)

    # PR state must match exactly what was reviewed.
    pv = run(["gh", "pr", "view", pr, "--json",
              "state,isDraft,headRefOid,baseRefName,statusCheckRollup"])
    if pv.returncode != 0:
        die(f"gh pr view {pr} failed: {pv.stderr.strip()}", 14)
    info = json.loads(pv.stdout)
    # Idempotent recovery: if a previous run merged the PR but died before recording it (observed
    # live: gh's --delete-branch failed on the worktree-held local branch AFTER the merge landed,
    # exiting before atomic_write), a re-run must record the merge, not refuse it. Only for the
    # exact reviewed commit — anything else is still refused below.
    if info.get("state") == "MERGED" and info.get("headRefOid") == worker_commit:
        merge_tip = _base_tip(base_branch)
        result = {**result, "merged": True, "merged_pr": pr, "merged_at": now(),
                  "merge_base_tip": merge_tip,
                  "merged_by": "orchestrator (AUTONOMY grant; recorded on re-run)"}
        atomic_write(rp, json.dumps(result, indent=2))
        write_state(spec_id, {**(read_state(spec_id) or {}), "status": "passed_pr_opened",
                              "merged": True, "merged_pr": pr})
        print(json.dumps({"attempt_id": attempt_id, "merged_pr": pr,
                          "base_branch": base_branch, "new_tip": merge_tip,
                          "note": "already merged; recorded"}, indent=2))
        return
    if info.get("state") != "OPEN":
        die(f"PR #{pr} state={info.get('state')} (not OPEN); refuse.", 14)
    if info.get("baseRefName") != base_branch:
        die(f"PR #{pr} base={info.get('baseRefName')} != {base_branch}; refuse.", 14)
    if info.get("headRefOid") != worker_commit:
        die(f"PR #{pr} head {info.get('headRefOid')[:9]} != reviewed worker_commit "
            f"{worker_commit[:9]}; the diff changed since review; refuse.", 14)
    ci_ok = any((c.get("name") == "ci" or c.get("context") == "ci")
                and (c.get("conclusion") == "SUCCESS" or c.get("state") == "SUCCESS")
                for c in (info.get("statusCheckRollup") or []))
    if not ci_ok:
        die(f"required check 'ci' not green on PR #{pr}; refuse.", 14)

    # THE merge-time base-check (closes SOL's post-PR stale-base hole).
    current = _base_tip(base_branch)
    if current != base_sha:
        write_state(spec_id, {**(read_state(spec_id) or {}), "status": "stale_base",
                              "error_class": ERR_STALE_BASE,
                              "detail": f"merge refused: {base_branch} advanced "
                                        f"{base_sha[:9]} -> {current[:9]} since review; re-run a "
                                        f"fresh attempt (all gates) before this can merge."})
        die(f"STALE BASE at merge: {base_branch} moved {base_sha[:9]} -> {current[:9]} since the "
            f"attempt was reviewed. Refusing to merge #{pr}; re-launch a fresh attempt.", 15)

    # All gates green and base current — merge (un-draft first if needed).
    if info.get("isDraft"):
        run(["gh", "pr", "ready", pr])
    # No --delete-branch here: gh also deletes the LOCAL branch, which is still checked out in the
    # attempt's worktree — that fails AFTER the merge lands, killing the run before it records the
    # merge (observed live, SPEC-009). integrate's cleanup deletes the remote branch after the
    # worktree is removed.
    mg = run(["gh", "pr", "merge", pr, "--merge"])
    if mg.returncode != 0:
        die(f"gh pr merge #{pr} failed: {mg.stderr.strip()}", 16)
    merge_tip = _base_tip(base_branch)
    result = {**result, "merged": True, "merged_pr": pr, "merged_at": now(),
              "merge_base_tip": merge_tip, "merged_by": "orchestrator (AUTONOMY grant)"}
    atomic_write(rp, json.dumps(result, indent=2))
    write_state(spec_id, {**(read_state(spec_id) or {}), "status": "passed_pr_opened",
                          "merged": True, "merged_pr": pr})
    print(json.dumps({"attempt_id": attempt_id, "merged_pr": pr, "base_branch": base_branch,
                      "new_tip": merge_tip}, indent=2))


# ============================================================== integrate =====
def _topo_specs(spec_ids: list[str]) -> list[str]:
    """Order the given specs so that depends_on (restricted to the given set) come first."""
    deps = {s: [d for d in load_spec(s).get("depends_on", []) if d in spec_ids]
            for s in spec_ids}
    ordered, seen = [], set()

    def visit(s, stack):
        if s in seen:
            return
        if s in stack:
            die(f"depends_on cycle involving {s}", 19)
        for d in deps[s]:
            visit(d, stack | {s})
        seen.add(s)
        ordered.append(s)

    for s in spec_ids:
        visit(s, set())
    return ordered


def _provenance_paths(spec_id: str, digest: str) -> list[str]:
    """Repo-relative provenance paths for one spec. Attempt state is gitignored — an on-box
    audit record, not repo content — so only spec, approvals, and escalations are staged."""
    paths = [f"specs/{spec_id}.yaml"]
    paths += [str(p.relative_to(ROOT)) for p in APPROVALS.glob(f"{digest}*.json")]
    paths += [str(p.relative_to(ROOT)) for p in ESCALATIONS.glob(f"{spec_id}-*.json")]
    return paths


def _commit_provenance(spec_ids: list[str]) -> str | None:
    """Auto-commit the tracked provenance for the given specs: branch → PR → ci → merge.
    Returns the PR url (or None if nothing to commit). Runs AFTER all worker merges so the
    ready-for-main tip only moves when no sibling attempt merge could go stale because of it."""
    branch = f"orch/prov-{'-'.join(s.replace('SPEC-', '') for s in spec_ids)}"
    git("checkout", "--quiet", "ready-for-main")
    git("pull", "--quiet", "--ff-only", "origin", "ready-for-main")
    run(["git", "branch", "-D", branch], cwd=str(ROOT))  # tolerate leftovers
    git("checkout", "--quiet", "-b", branch)
    try:
        for sid in spec_ids:
            for p in _provenance_paths(sid, spec_digest(sid)):
                run(["git", "add", "--", p], cwd=str(ROOT))
        if not git("diff", "--cached", "--name-only").strip():
            return None
        ids = ", ".join(spec_ids)
        git("commit", "-q", "-m",
            f"provenance: {ids}\n\nAuto-committed by dispatch integrate (Gate 4): spec, "
            f"approval(s), and any escalations. Attempt evidence stays gitignored — an "
            f"on-box audit record (see SECURITY.md).")
        git("push", "-u", "origin", branch)
        pr = run(["gh", "pr", "create", "--base", "ready-for-main", "--head", branch,
                  "--title", f"provenance: {ids}",
                  "--body", "Auto-committed provenance (dispatch integrate, Gate 4 / "
                            "Level 1.5 grant). Spec + approvals + escalations; attempt "
                            "evidence stays gitignored (on-box audit record)."], cwd=str(ROOT))
        if pr.returncode != 0:
            die(f"provenance PR create failed: {pr.stderr.strip()}", 20)
        pr_url = (pr.stdout or "").strip().splitlines()[-1]
        prn = _pr_number(pr_url)
        # Merge only on an exact-name ci=SUCCESS (B7). The old code broke its wait loop on the bare
        # word "pass" OR "fail" in `gh pr checks` text and then merged UNCONDITIONALLY — so a failed
        # ci still triggered the merge, backstopped only by branch protection, and a stray substring
        # could release the wait early (observed live, provenance PR #19).
        _provenance_merge(prn)
        return pr_url
    finally:
        git("checkout", "--quiet", "ready-for-main")
        git("pull", "--quiet", "--ff-only", "origin", "ready-for-main")


def integrate_suite_env() -> dict:
    """Environment for the post-merge suite in the materialized grader tree (B9 rounds 1-2).

    Strict mode is forced — without it a box test returning 77 (skip) in the grader worktree
    counts as a pass, so the combined tree was never actually verified. But the grader tree has
    no gitignored .venv, so the venv-dependent dispatcher self-tests would then skip-and-fail:
    the suite must be handed a usable interpreter. Preference order: the root-owned trusted test
    runtime (same source as the gate tests' ORCH_TEST_PY), else this repo's own .venv (the same
    interpreter `./scripts/test` uses when run from ROOT — the operator's, not a worker's). If
    neither exists, ORCH_TEST_PY stays unset and the strict suite fails LOUDLY: a box that
    cannot run the dispatcher self-tests cannot certify the combined tree (fail closed).
    """
    env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1", "ORCH_TEST_STRICT": "1"}
    # Round-3: never pass through an inherited ORCH_TEST_PY — the selection below is the policy,
    # and an inherited value (e.g. from an outer test run) may point at a stale interpreter.
    env.pop("ORCH_TEST_PY", None)
    rt = trusted_test_runtime()
    venv_py = ROOT / ".venv" / "bin" / "python"
    if rt:
        env["ORCH_TEST_PY"] = rt["python"]
    elif venv_py.exists():
        env["ORCH_TEST_PY"] = str(venv_py.resolve())
    return env


def run_integrate_suite(gtree: Path):
    """Launch the post-merge suite in the materialized grader tree with integrate_suite_env().

    Split out of cmd_integrate so the suite-launch contract (command, cwd, environment) is a
    directly testable unit rather than a source-inspection tripwire (B9 round-3)."""
    return run([str(gtree / "scripts" / "test")], cwd=str(gtree), env=integrate_suite_env())


def cmd_integrate(attempt_ids: list[str]) -> None:
    """Gate 4 §3: deterministic integration. Merge passed attempts in depends_on order (each via
    the fail-closed `merge`, so the base-check applies per merge — the FIRST stale sibling stops
    the run for a fresh re-attempt); re-run the repo suite after every merge; clean up the
    attempt's worktree/branch; auto-commit provenance at the end. A merge conflict or suite
    failure is stop/escalate — never AI-resolved."""
    if load_autonomy() is None:
        die("autonomy not granted; integrate is an auto-merge path (Level 1.5+).", 12)
    if HALT.exists():
        die(f"HALT present ({HALT}); refusing to integrate.", 3)

    parsed = [parse_attempt_id(a) for a in attempt_ids]
    by_spec = {s: n for s, n in parsed}
    order = _topo_specs(list(by_spec))
    report = {"integrated": [], "provenance_pr": None}

    git("checkout", "--quiet", "ready-for-main")
    for sid in order:
        aid = f"{sid}-{by_spec[sid]}"
        mg = run([str(ROOT / "scripts" / "dispatch"), "merge", aid])
        if mg.returncode != 0:
            path = escalate(sid, f"integrate stopped at {aid}: merge refused/failed "
                                 f"(rc={mg.returncode})",
                            {"stderr": (mg.stderr or "").strip(),
                             "integrated_so_far": report["integrated"]})
            report["stopped_at"] = {"attempt_id": aid, "rc": mg.returncode,
                                    "stderr": (mg.stderr or "").strip(),
                                    "escalation": str(path)}
            print(json.dumps(report, indent=2))
            sys.exit(mg.returncode)
        git("pull", "--quiet", "--ff-only", "origin", "ready-for-main")
        # Findings 1+2: the just-merged commit is what would land. Grade it from an IMMUTABLE
        # checkout of that commit OUTSIDE the working tree — never the filesystem `./scripts/test`,
        # whose `tests/*.sh` glob + scripts/test would otherwise run dirty/replaced/untracked
        # working-tree bytes a same-uid process can swap mid-run. grader_drift() stays as a fast
        # pre-check (a drifted post-merge working tree is itself suspicious) but is no longer what
        # keeps the grade honest — running from the pinned tree is.
        merged_commit, drift = integration_grade_gate()
        if drift:
            path = escalate(sid, f"integration grader drift after {aid}: the post-merge working "
                                 f"tree differs from commit {merged_commit[:9]}; refusing to grade",
                            {"merged_commit": merged_commit, "grader_drift": drift,
                             "integrated_so_far": report["integrated"]})
            report["stopped_at"] = {"attempt_id": aid, "grader_drift": drift,
                                    "escalation": str(path)}
            print(json.dumps(report, indent=2))
            sys.exit(21)
        with materialized_grader_tree(merged_commit, ROOT) as gtree:
            # round-3: export GIT_NO_REPLACE_OBJECTS into the suite's environment — the grader
            # worktree shares the object store/refs-replace, so scripts/test and each tests/*.sh
            # it globs must read objects with replacement disabled too.
            ts = run_integrate_suite(gtree)
        if ts.returncode != 0:
            path = escalate(sid, f"post-merge suite FAILED on ready-for-main after {aid} — "
                                 f"stop; human decision required",
                            {"test_tail": ((ts.stdout or "") + (ts.stderr or ""))[-2000:]})
            report["stopped_at"] = {"attempt_id": aid, "suite": "FAILED",
                                    "escalation": str(path)}
            print(json.dumps(report, indent=2))
            sys.exit(21)
        for wt in (ISO_WORKTREES / aid, WORKTREES / aid):   # D5 worktrees live under /srv now
            if wt.exists():
                run(["git", "worktree", "remove", "--force", str(wt)], cwd=str(ROOT))
        # R73 Job 2: delete the FROZEN branch from the attempt's own launch record instead of
        # reconstructing codex/{attempt_id}. Round-1 review (BLOCKING): the recorded value is
        # data feeding destructive local+remote deletion, so it must prove it belongs to THIS
        # attempt before anything is deleted — valid_attempt_branch requires one namespace
        # segment plus the exact attempt id, which no base/protected/owner branch ever carries.
        # Anything unreadable or failing that proof leaves the branch for manual cleanup — a
        # leftover branch is visible and harmless; deleting a guessed or corrupt name is neither.
        try:
            lc_branch = json.loads(
                (ATTEMPTS / sid / str(by_spec[sid]) / "launch.json").read_text())["branch"]
        except Exception as exc:
            print(f"note: {aid}: launch.json branch unreadable ({exc}); "
                  f"branch left for manual cleanup")
            lc_branch = None
        if lc_branch is not None and not valid_attempt_branch(lc_branch, aid):
            print(f"note: {aid}: recorded branch {lc_branch!r} does not name this attempt's "
                  f"worker namespace; branch left for manual cleanup")
            lc_branch = None
        if lc_branch:
            run(["git", "branch", "-D", lc_branch], cwd=str(ROOT))
            run(["git", "push", "-q", "origin", "--delete", lc_branch], cwd=str(ROOT))
        report["integrated"].append(aid)

    report["provenance_pr"] = _commit_provenance(order)
    print(json.dumps(report, indent=2))


# ================================================================= main =======
def main() -> None:
    ap = argparse.ArgumentParser(prog="dispatch")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("launch",):
        p = sub.add_parser(name)
        p.add_argument("spec_id")
    for name in ("status", "cancel", "timeout", "merge", "continue", "_run", "_grade"):
        p = sub.add_parser(name)
        p.add_argument("attempt_id")
    pw = sub.add_parser("await")
    pw.add_argument("attempt_id")
    pw.add_argument("--show-stderr", action="store_true",
                    help="on failure, also print a LOCAL tail of raw/worker-stderr.txt "
                         "(may contain secrets; never persisted)")
    ph = sub.add_parser("health")
    ph.add_argument("attempt_id")
    ph.add_argument("--minutes", type=int, default=HEALTH_INACTIVITY_MIN,
                    help="inactivity threshold before an alert (default 10)")
    sub.add_parser("reconcile")
    pi = sub.add_parser("integrate")
    pi.add_argument("attempt_ids", nargs="+")
    args = ap.parse_args()

    if args.cmd == "launch":
        cmd_launch(args.spec_id)
    elif args.cmd == "status":
        cmd_status(args.attempt_id)
    elif args.cmd == "await":
        cmd_await(args.attempt_id, show_stderr=args.show_stderr)
    elif args.cmd == "cancel":
        cmd_cancel(args.attempt_id)
    elif args.cmd == "timeout":
        cmd_timeout(args.attempt_id)
    elif args.cmd == "merge":
        cmd_merge(args.attempt_id)
    elif args.cmd == "health":
        cmd_health(args.attempt_id, args.minutes)
    elif args.cmd == "reconcile":
        cmd_reconcile()
    elif args.cmd == "integrate":
        cmd_integrate(args.attempt_ids)
    elif args.cmd == "continue":
        cmd_continue(args.attempt_id)
    elif args.cmd == "_run":
        _run(args.attempt_id)
    elif args.cmd == "_grade":
        _grade(args.attempt_id)


if __name__ == "__main__":
    main()
