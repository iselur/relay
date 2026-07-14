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
  - Structured error classes. MAX_PARALLEL=2 (Gate 3 part 3): unique branch/worktree per attempt,
    atomic slot claim; a base that moved while an attempt ran (a sibling integrated) is refused at
    push (stale_base) and re-run by the orchestrator as a fresh attempt. No auto-remediation.
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
QUALITY_DIMENSIONS = ("maintainability", "design_fit", "test_quality")

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
}
LIVE = {"launching", "running"}

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
    if spec.get("regression_command") and not spec.get("regression_test_paths"):
        errors.append("regression_command requires non-empty regression_test_paths (the test files to "
                      "overlay onto the base, so the base run fails for the right reason).")
    return spec, errors


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

    # needs_network hard-refused (the operator decision, residual risk 13-B).
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

    # depends_on all done.
    for dep in spec.get("depends_on", []):
        st = read_state(dep)
        if not st or st.get("status") != "passed_pr_opened":
            die(f"dependency {dep} not satisfied (state="
                f"{st.get('status') if st else 'none'}).", 7)

    # NOTE: the MAX_PARALLEL concurrency check is NOT here — it must be atomic with the state
    # write so two concurrent launches cannot both pass it. See claim_slot(), called from
    # cmd_launch under the STATE lock.
    return {"spec": spec, "digest": digest, "approval": approval}


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
                try:
                    states.append(json.loads(p.read_text()))
                except Exception:
                    pass
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


OPERATOR_USER, OPERATOR_HOME = _resolve_operator()

WORKER_USER = "codex-worker"
WORKER_HOME = Path("/home/codex-worker")
ISO_WORKTREES = Path("/srv/codexwork/worktrees")
CODEX_PKG = OPERATOR_HOME / ".local/lib/node_modules/@openai/codex"  # npm layout; bind-mounted RO to /opt/codex


def worker_codex_runtime():
    """How an ISOLATED worker runs Codex: (argv prefix, read-only bind mounts), or None when this
    box has no worker-launchable install. The worker cannot read the operator's home (that IS the
    boundary), so root bind-mounts the runtime past it. Two layouts are launchable: the npm
    package (needs a system node — the worker cannot reach ~/.local), or a native single ELF
    binary. None must refuse at launch: the old npm-only assumption died opaquely in namespace
    setup on a native-install box, identically on every retry (dev-box feedback, R51)."""
    if (CODEX_PKG / "bin/codex.js").is_file() and Path("/usr/bin/node").is_file():
        return ["/usr/bin/node", "/opt/codex/bin/codex.js"], [(str(CODEX_PKG), "/opt/codex")]
    import shutil
    cands = [OPERATOR_HOME / ".codex/bin/codex", OPERATOR_HOME / ".local/bin/codex",
             Path("/usr/local/bin/codex"), Path("/usr/bin/codex")]
    which = shutil.which("codex")
    if which:
        cands.append(Path(which))
    for cand in cands:
        try:
            real = cand.resolve(strict=True)
            with real.open("rb") as fh:
                elf = fh.read(4) == b"\x7fELF"
        except OSError:
            continue
        if elf:  # an npm shim here would still need node; only a real binary is self-sufficient
            return ["/opt/codex/codex"], [(str(real), "/opt/codex/codex")]
    return None


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


def isolated_run(unit, argv, cwd, rw_paths, private_network, ceiling_s, stdout, stderr,
                 binds=None, env_extra=None):
    """Run argv as codex-worker in a hardened transient SYSTEM service; block for completion.
    Writes are confined to rw_paths; the operator's home is inaccessible; the gate test passes
    private_network=True (untrusted code, no API needed). The service is a system unit (own cgroup,
    own RuntimeMaxSec) — store `unit` so cancel/health can stop it independently of the outer unit."""
    # NOTE: no ProtectHome — it would tmpfs-hide the worker's OWN CODEX_HOME (auth). the operator's home is
    # blocked explicitly by InaccessiblePaths + DAC; the worker's own home stays accessible.
    props = ["--property=ProtectSystem=strict",
             f"--property=InaccessiblePaths={OPERATOR_HOME}", "--property=PrivateTmp=yes",
             "--property=NoNewPrivileges=yes", "--property=RestrictSUIDSGID=yes",
             "--property=UMask=0007", f"--property=RuntimeMaxSec={ceiling_s}"]
    for p in rw_paths:
        props.append(f"--property=ReadWritePaths={p}")
    for src, dst in (binds or []):
        props.append(f"--property=BindReadOnlyPaths={src}:{dst}")
    if private_network:
        props.append("--property=PrivateNetwork=yes")
    if cwd:
        props.append(f"--property=WorkingDirectory={cwd}")
    envs = {"HOME": str(WORKER_HOME), "PATH": "/usr/bin:/bin",
            "CODEX_HOME": str(WORKER_HOME / ".codex"), "TERM": "dumb", "LANG": "C.UTF-8",
            **(env_extra or {})}
    setenvs = [f"--setenv={k}={v}" for k, v in envs.items()]
    cmd = ["sudo", "-n", "systemd-run", f"--uid={WORKER_USER}", f"--gid={WORKER_USER}",
           "--pipe", "--wait", "--quiet", "--collect", f"--unit={unit}", *props, *setenvs,
           "--", *argv]
    with open(os.devnull) as devnull:
        return subprocess.run(cmd, stdin=devnull, stdout=stdout, stderr=stderr)


def last_agent_message(events_path: Path) -> str:
    """Recover the worker's final message from the JSONL stream (isolated workers can't write the
    evidence dir under the operator's home, so --output-last-message is unavailable)."""
    msg = ""
    try:
        for line in events_path.read_text().splitlines():
            try:
                e = json.loads(line)
            except Exception:
                continue
            it = e.get("item") or {}
            if it.get("type") == "agent_message" and it.get("text"):
                msg = it["text"]
    except Exception:
        pass
    return msg


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


def run_regression_gate(lc, wt, worker_commit, att, iso, ceiling_s) -> dict:
    """Prove the change's new test actually CATCHES the intended defect (holistic-review #1, SOL).

    A test that passes on the candidate proves nothing about whether it would have failed on the bug
    it claims to fix. So: run the human-authored `regression_command` against a throwaway worktree at
    the base commit with the candidate's `regression_test_paths` overlaid — it MUST fail there (the
    fix is absent) — and against the candidate — it MUST pass. Overlaying the test files is what makes
    the base failure meaningful: it fails because the assertion is unmet, not because the test file is
    missing. Runs worker-authored code → isolated exactly like the test phase (network off).
    Returns a result dict; result=="PASS" iff base FAILS and candidate PASSES."""
    cmd = lc["regression_command"]
    paths = lc.get("regression_test_paths", [])
    base_sha = lc["base_sha"]
    attempt_id = lc["attempt_id"]
    base_wt = worktree_root() / f"{attempt_id}-regbase"
    res = {"command": cmd, "test_paths": paths, "base_sha": base_sha,
           "worker_commit": worker_commit, "isolation": iso,
           "base_exit": None, "candidate_exit": None, "result": "FAIL", "reason": ""}

    def _run_in(unit, cwd, log_path):
        if iso:
            with open(log_path, "w") as lg:
                cp = isolated_run(unit, ["bash", "-c", cmd], cwd=str(cwd),
                                  rw_paths=[str(cwd)], private_network=True, ceiling_s=ceiling_s,
                                  stdout=lg, stderr=subprocess.STDOUT)
            return cp.returncode
        cp = run(["bash", "-c", cmd], cwd=str(cwd))
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
        res["base_exit"] = _run_in(f"codex-regbase-{attempt_id}", base_wt,
                                   att / "regression-base.log")
        res["candidate_exit"] = _run_in(f"codex-regcand-{attempt_id}", wt,
                                        att / "regression-candidate.log")
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
    iso = isolation_available()
    exposed = os.environ.get("ORCH_ALLOW_UNISOLATED") == "1"
    if not iso and not exposed:
        die("REFUSING to launch: worker isolation (D5) is unavailable.\n"
            "  Worker code would run as YOU — your home, your credentials, your network.\n"
            "  Fix it:        ./scripts/setup-worker-user.sh\n"
            "  Or accept it:  ORCH_ALLOW_UNISOLATED=1 ./scripts/dispatch launch " + spec_id + "\n"
            "                 (that is FULL EXPOSURE, not a sandbox — it is recorded in the evidence)",
            ERR_NO_ISOLATION_RC)
    if not iso and exposed:
        print("!!! UNISOLATED: worker code runs as the operator with full access to this host,\n"
              "!!! its credentials and its network. You asked for this (ORCH_ALLOW_UNISOLATED=1).\n"
              "!!! It is recorded in launch.json and in the reviewer's evidence.", file=sys.stderr)

    # Same fail-fast doctrine for the worker's Codex runtime: an isolated launch without one dies
    # in namespace setup AFTER the attempt is claimed — opaquely, identically on every retry.
    if iso and worker_codex_runtime() is None:
        die("REFUSING to launch: no worker-launchable Codex runtime on this box.\n"
            "  Isolated workers need EITHER the npm package\n"
            "  (~/.local/lib/node_modules/@openai/codex + a system node at /usr/bin/node)\n"
            "  OR a native codex ELF binary (~/.codex/bin, ~/.local/bin, /usr/local/bin,\n"
            "  /usr/bin, or on PATH).\n"
            "  Fix: npm install -g --prefix ~/.local @openai/codex   (plus a system node),\n"
            "       or install the native binary. Then relaunch.", 15)

    ctx = preflight(spec_id)
    spec, digest, approval = ctx["spec"], ctx["digest"], ctx["approval"]

    n = next_attempt(spec_id)
    # Gate 4: remediation budget + stop-early + high-risk per-dispatch approval. Dies (recording
    # failed_remediation_exhausted + escalation) if this launch is not permitted.
    remediation = remediation_preflight(spec_id, spec, digest, n)
    attempt_id = f"{spec_id}-{n}"
    att_dir = ATTEMPTS / spec_id / str(n)
    (att_dir / "raw").mkdir(parents=True, exist_ok=True)
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

    try:
        git("fetch", "--quiet", "origin", approval.get("base_branch", "ready-for-main"))
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
        "base_branch": approval.get("base_branch", "ready-for-main"),
        "worktree": str(wt), "worker_model": approval.get("worker_model", "gpt-5.6-sol"),
        "worker_effort": approval.get("worker_reasoning_effort", "high"),
        "reviewer_model": approval.get("reviewer_model", "claude-fable-5"),
        "reviewer_effort": approval.get("reviewer_effort", "high"),
        "test_command": spec["test_command"], "approved_scope": approval["approved_scope"],
        "regression_command": spec.get("regression_command"),
        "regression_test_paths": spec.get("regression_test_paths", []),
        "hard_ceiling_hours": ceiling_h, "remediation": remediation,
        # T2: the frozen decision + why it was allowed. `exposure_accepted` is the operator's
        # knowing "yes, run this as me" — provenance never overstates the boundary.
        "isolation": iso, "exposure_accepted": (not iso and exposed),
        "worker_unit": f"codex-worker-{attempt_id}",
        "test_unit": f"codex-test-{attempt_id}", "created": now(),
    }, indent=2))

    unit = unit_name(spec_id, n)
    cmd = [
        "systemd-run", "--user", f"--unit={unit}", "--collect",
        f"--property=Description=Codex worker {attempt_id}",
        f"--property=RuntimeMaxSec={ceiling_s}",   # hard ceiling (D10), default-on
        "--setenv=HOME=" + os.environ.get("HOME", str(OPERATOR_HOME)),
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
            "isolation": ("D5: codex-worker uid, systemd-hardened, the operator's home inaccessible, test "
                          "phase network-off" if lc.get("isolation") else "same-user (the operator) fallback, "
                          "codex bwrap sandbox"),
            "test_command": lc["test_command"], "status": status,
            "error_class": err_class, "commit_policy": "orchestrator-commits (G1-A/C)",
            "finished": now(), **extra,
        }
        atomic_write(att / "result.json", json.dumps(result, indent=2))
        write_state(spec_id, {"attempt_id": attempt_id, "spec_id": spec_id, "attempt": n,
                              "spec_digest": lc["spec_digest"], "status": status,
                              "error_class": err_class, "unit": unit_name(spec_id, n),
                              **{k: extra[k] for k in ("worker_commit", "pr_url", "detail",
                                                       "worker_exit") if k in extra}})
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
    (raw / "worker-prompt.txt").write_text(prompt)

    # T2: consume the FROZEN launch decision — never recompute isolation here. A launch record that
    # says "unisolated" without a recorded operator acceptance is not a thing cmd_launch can produce,
    # so if we see one, the record was tampered with or hand-edited: refuse rather than run worker
    # code as the operator on the strength of a file.
    iso = lc.get("isolation", False)
    if not iso and not lc.get("exposure_accepted"):
        finish("failed_launch", ERR_NO_ISOLATION,
               detail="launch record has isolation:false without a recorded operator exposure "
                      "acceptance — refusing to run worker code as the operator")
    ceiling_s = int(float(lc.get("hard_ceiling_hours", DEFAULT_CEILING_HOURS)) * 3600)
    # Codex flags common to both paths. Fast mode (priority service tier): faster wall-clock at the
    # SAME model + reasoning depth. `service_tier` is the real key (`model_service_tier` is rejected).
    codex_args = ["exec", "--cd", str(wt),
                  "-m", lc["worker_model"], "-c", f"model_reasoning_effort={lc['worker_effort']}",
                  "-c", "service_tier=priority", "--skip-git-repo-check", "--json"]
    with open(raw / "events.jsonl", "w") as ev, open(raw / "worker-stderr.txt", "w") as er:
        if iso:
            # D5: worker runs as codex-worker in a hardened system service. Codex's own sandbox is
            # OFF (-s danger-full-access) because it won't construct under the bind-mounted UID;
            # ProtectSystem=strict + ReadWritePaths confine writes and InaccessiblePaths=the operator's home
            # + DAC confine reads. --output-last-message is dropped (worker can't write the operator's home);
            # the final message is recovered from the JSONL stream.
            runtime = worker_codex_runtime()
            if runtime is None:
                finish("failed_worker_error", ERR_WORKER,
                       detail="no worker-launchable Codex runtime (launch preflight should have "
                              "refused); install the npm package + system node, or a native binary")
            argv_prefix, binds = runtime
            argv = [*argv_prefix, *codex_args, "-s", "danger-full-access", prompt]
            wc = isolated_run(
                lc["worker_unit"], argv, cwd=str(wt),
                rw_paths=[str(wt), str(WORKER_HOME / ".codex")],
                private_network=False, ceiling_s=ceiling_s, stdout=ev, stderr=er,
                binds=binds)
        else:
            # Fallback (fresh box / CI): same-user launch with Codex's bwrap sandbox.
            scrubbed = {
                "HOME": str(OPERATOR_HOME), "USER": OPERATOR_USER, "LOGNAME": OPERATOR_USER,
                "PATH": f"{OPERATOR_HOME}/.local/bin:/usr/bin:/bin",
                "CODEX_HOME": f"{OPERATOR_HOME}/.codex", "TERM": "dumb", "LANG": "C.UTF-8",
            }
            worker_cmd = ["codex", *codex_args, "--sandbox", "workspace-write",
                          "--output-last-message", str(raw / "worker-last-message.txt"), prompt]
            with open(os.devnull) as devnull:
                wc = subprocess.run(worker_cmd, env=scrubbed, stdin=devnull, stdout=ev, stderr=er)

    stderr_txt = (raw / "worker-stderr.txt").read_text()
    if iso:
        last_message = last_agent_message(raw / "events.jsonl")
    else:
        last_message = (raw / "worker-last-message.txt").read_text() \
            if (raw / "worker-last-message.txt").exists() else ""

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
               detail=f"worker error class={ec}; stderr tail: "
                      f"{stderr_txt[-800:].strip() or '(empty)'}")

    # --- D5 path-safety gate: reject planted symlinks/special files BEFORE any operator-context step
    # touches worker output (no later the operator process should be able to follow a link into the operator's files).
    unsafe = validate_worktree_safe(wt)
    if unsafe:
        finish("failed_scope", ERR_SCOPE, worker_exit=wc.returncode,
               detail=f"unsafe filesystem entries planted by worker (symlink/fifo/socket/device): "
                      f"{unsafe[:20]}")

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
    # The test_command runs WORKER-PRODUCED code — the real exfiltration path (SOL, D5). Under D5 it
    # runs as codex-worker with PrivateNetwork=yes (no API needed) and the operator's home inaccessible, so a
    # malicious test can neither read the operator's creds nor phone home. Otherwise it runs as the operator (fallback).
    # T1 (R26): the runner writes a machine-readable PASS/SKIP/FAIL line per test to this path. The
    # summary is written INSIDE the worktree (the worker's own writable area) but we only ever trust
    # it to tell us what DIDN'T run — a worker that forges "PASS" for a test it deleted still fails,
    # because the required set comes from the ORCHESTRATOR's checkout (required_tests()) and every
    # required test must appear. The worker cannot add tests to our required list, only fail to
    # satisfy it.
    summary_path = wt / ".orch-test-summary"
    test_env = {"ORCH_TEST_SUMMARY": str(summary_path)}

    # T1b (R26) — HOLD THE GRADER OUT OF THE AGENT'S REACH.
    # T1 made the orchestrator choose WHICH tests are required. That is not enough: the tests still
    # EXECUTE from the worker's worktree, so a candidate whose approved scope includes tests/ can
    # rewrite a required test to `exit 0` and pass the gate honestly. (Demonstrated, not theorised.)
    # Every reward-hacking result in the literature reduces to the agent being able to touch the
    # thing that scores it: METR observed o3 monkey-patching the evaluator and stealing the reference
    # answer on 100% of trajectories for one task.
    #
    # So: the REQUIRED tests are restored from the ORCHESTRATOR's installed copy before the gate runs.
    # A worker's edits to a required test are recorded and run only as SUPPLEMENTAL evidence — they
    # can never satisfy the required set. A legitimately changed test becomes authoritative only once
    # it is merged and installed (i.e. after a human has looked at it).
    substituted = []
    for rel in required_tests():
        parent_copy, worker_copy = ROOT / rel, wt / rel
        if not parent_copy.exists():
            continue
        parent_bytes = parent_copy.read_bytes()
        if not worker_copy.exists() or worker_copy.read_bytes() != parent_bytes:
            if worker_copy.exists():
                (att / "raw" / f"worker-{Path(rel).name}").write_bytes(worker_copy.read_bytes())
                substituted.append(rel)
            worker_copy.parent.mkdir(parents=True, exist_ok=True)
            worker_copy.write_bytes(parent_bytes)
            worker_copy.chmod(0o755)
    if iso:
        with open(att / "test.log", "w") as tl:
            tcp = isolated_run(
                lc["test_unit"], ["bash", "-c", lc["test_command"]], cwd=str(wt),
                rw_paths=[str(wt)], private_network=True, ceiling_s=ceiling_s,
                env_extra=test_env, stdout=tl, stderr=subprocess.STDOUT)
        test_rc = tcp.returncode
    else:
        tc = run(["bash", "-c", lc["test_command"]], cwd=str(wt), env={**os.environ, **test_env})
        (att / "test.log").write_text((tc.stdout or "") + (tc.stderr or ""))
        test_rc = tc.returncode
    if test_rc != 0:
        finish("failed_test", ERR_TEST, worker_commit=worker_commit, test_exit=test_rc)

    # T1 (R26) — THE FIX for SPEC-015/1's false PASS. Exit code 0 is NOT evidence that the required
    # tests ran: three trust-class tests SKIPped, `./scripts/test` still exited 0, and the reviewer
    # certified them as proof. A test that did not RUN has not PASSED.
    summary_txt = summary_path.read_text() if summary_path.exists() else ""
    ran = parse_test_summary(summary_txt)
    req = required_tests()
    attested, detail = attest_tests(ran, req)
    attestation = {"required": req, "observed": ran, "attested": attested, "detail": detail,
                   # T1b: required tests the worker had modified. Their content was REPLACED with the
                   # orchestrator's copy before the gate ran; the worker's versions are retained in
                   # raw/ as evidence and are visible to the reviewer, but they graded nothing.
                   "required_tests_restored_from_parent": substituted}
    atomic_write(att / "test-attestation.json", json.dumps(attestation, indent=2))
    if not attested:
        finish("failed_test", ERR_TEST_NOT_RUN, worker_commit=worker_commit,
               test_exit=test_rc, attestation=attestation)

    # --- step 7.5: OPTIONAL regression-proof gate (holistic-review #1) ----------
    # Prove the change's new test actually CATCHES the intended defect: the human-authored
    # regression_command must FAIL on the base (with the candidate's test files overlaid, so it fails
    # for the right reason) and PASS on the candidate. A vacuous test (passes on base too) is a merit
    # failure. Runs worker-authored code → isolated (network off) like the test phase.
    if lc.get("regression_command"):
        reg = run_regression_gate(lc, wt, worker_commit, att, iso, ceiling_s)
        atomic_write(att / "regression.json", json.dumps(reg, indent=2))
        if reg["result"] != "PASS":
            finish("failed_regression", ERR_REGRESSION, worker_commit=worker_commit, regression=reg)

    # --- step 8: reviewer (bound, fail-closed) --------------------------------
    verdict, vraw = review(att, spec_id, lc, worker_commit, detail)
    atomic_write(att / "review.json", json.dumps(verdict, indent=2) if verdict else "{}")
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
    base_branch = lc.get("base_branch", "ready-for-main")
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
    pr = run(["gh", "pr", "create", "--draft", "--base",
              "ready-for-main", "--head", lc["branch"],
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


def _verdict_schema_for_attempt(att: Path) -> dict:
    """Use the launch-time contract, with a repo-schema fallback for historical attempts."""
    pinned = att / "verdict.schema.json"
    return json.loads((pinned if pinned.exists() else VERDICT_SCHEMA).read_text())


def parse_test_summary(text: str) -> dict[str, str]:
    """Parse `scripts/test`'s machine-readable summary: one `PASS|SKIP|FAIL <path>` per line.

    Only the summary lines are authoritative. Worker prose in test.log is NOT parsed — a worker
    can print anything it likes, so the ONLY thing we trust is the runner's own per-test exit code,
    which is what produced these lines (see scripts/test)."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0] in ("PASS", "SKIP", "FAIL"):
            out[parts[1].strip()] = parts[0]
    return out


def attest_tests(summary: dict[str, str], required: list[str]) -> tuple[bool, str]:
    """T1 (decision R26). A test that did not RUN has not PASSED.

    This is the fix for the SPEC-015/1 false PASS: three trust-class tests SKIPped, the aggregate
    command still exited 0, and the reviewer certified them as proof. Exit code 0 is NOT evidence
    that the required tests ran.

    Fail closed on:
      - an EMPTY required set (round-10 finding: zero tests + zero assertions is a vacuous,
        internally consistent "pass" — it must never authorize a review);
      - any required test missing from the runner's summary (it never reported);
      - any required test that SKIPped or FAILed.
    """
    if not required:
        return False, ("no required tests selected — an empty required-test set cannot certify "
                       "anything (fail closed)")
    problems = []
    for t in required:
        status = summary.get(t)
        if status is None:
            problems.append(f"{t}: NO RESULT (test never reported)")
        elif status != "PASS":
            problems.append(f"{t}: {status}")
    if problems:
        return False, "required tests did not run and pass: " + "; ".join(problems)
    return True, f"all {len(required)} required tests executed and passed"


def required_tests() -> list[str]:
    """Which tests MUST have run, selected by the ORCHESTRATOR from ITS OWN checkout — never from
    the worktree, so a candidate cannot shrink its own required set by deleting test files.

    Deliberately blunt: every test in the installed repo is required. One suite, it is fast, and a
    cleverer selector is exactly the kind of mechanism we are no longer building speculatively
    (R26 — gates are earned by real failures, not imagined ones)."""
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / "tests").glob("*.sh"))


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


def review(att: Path, spec_id: str, lc: dict, wc: str, test_attestation: str = "unknown"):
    # policy-note item 2: mandatory structured rubric. The worker's plan/checklist is NEVER
    # included here (confirmation-bias contamination) — only spec, diff, and orchestrator evidence.
    wt = Path(lc["worktree"])
    diff = git("diff", f"{lc['base_sha']}..{wc}", cwd=wt)
    schema_obj = _verdict_schema_for_attempt(att)
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
        "blocking scope/regression/security finding exists; otherwise FAIL. If evidence is "
        "missing or ambiguous, FAIL (fail closed). `reasons[]` must be non-empty. You MUST echo "
        "spec_digest, base_sha and worker_commit verbatim; the verdict is void otherwise. "
        f"schema_version is \"{schema_version}\"." + quality_instructions +
        "\n\n=== SPEC ===\n" + spec_path(spec_id).read_text() +
        f"\n\n=== BINDING ===\nspec_digest: {lc['spec_digest']}\nbase_sha: {lc['base_sha']}\n"
        f"worker_commit: {wc}\n\n=== EVIDENCE (from the orchestrator, not the worker) ===\n"
        f"integrity: PASS\nscope: PASS\n"
        # T1 (R26): the reviewer used to be told only "test_command exited 0" — which is how it
        # certified SPEC-015's three SKIPPED tests as proof. It now gets the orchestrator's own
        # per-test attestation. This is control-plane evidence, not worker-authored text.
        f"tests: {test_attestation}\n\n"
        "=== DIFF ===\n" + diff
    )
    (att / "raw" / "review-request.txt").write_text(req)
    # D5: the reviewer is a Claude process running as the operator, judging WORKER-CONTROLLED diff text — a
    # confused-deputy risk (SOL). It gets the full spec + diff + evidence in the prompt and needs NO
    # host filesystem access, so ALL tools (incl. Read/Grep/Glob) are denied: a prompt-injected
    # reviewer cannot browse the operator's files. Nothing to inspect beyond what the orchestrator provided.
    cmd = [
        "claude", "-p", "--output-format", "json", "--json-schema", json.dumps(schema_obj),
        "--model", lc["reviewer_model"].replace("claude-fable-5", "fable"),
        "--effort", lc["reviewer_effort"],
        "--disallowedTools", "Read", "Grep", "Glob", "Bash", "Write", "Edit", "NotebookEdit",
        "WebFetch", "WebSearch", "Task", "--permission-mode", "manual",
    ]
    cp = run(cmd, input=req)
    (att / "raw" / "review-envelope.json").write_text(cp.stdout or "")
    try:
        verdict = json.loads(json.loads(cp.stdout)["result"])
    except Exception:
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
        f"| worker | `{lc['worker_model']}` (reasoning={lc['worker_effort']}), sandbox=workspace-write, network=off |\n"
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
def cmd_await(attempt_id: str, interval: int = 5, max_wait: int = 8 * 3600) -> None:
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
            print(json.dumps(out))
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
def stop_worker_units(attempt_id: str) -> None:
    """D5: the worker/test run in transient SYSTEM units (own cgroups, NOT under the outer --user
    unit), so cancellation must stop them explicitly — first, before the outer unit."""
    for u in (f"codex-worker-{attempt_id}", f"codex-test-{attempt_id}"):
        run(["sudo", "-n", "systemctl", "stop", u])


def cmd_cancel(attempt_id: str) -> None:
    spec_id, n = parse_attempt_id(attempt_id)
    unit = unit_name(spec_id, n)
    stop_worker_units(attempt_id)                    # child system units first
    cp = run(["systemctl", "--user", "stop", unit])  # then the outer pipeline unit
    st = read_state(spec_id) or {}
    if st.get("attempt_id") == attempt_id and st.get("status") in LIVE:
        write_state(spec_id, {**st, "status": "interrupted", "error_class": "cancelled",
                              "detail": "cancelled by operator"})
    print(json.dumps({"attempt_id": attempt_id, "unit": unit,
                      "stop_rc": cp.returncode, "stderr": cp.stderr.strip()}))


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
                stop_worker_units(attempt_id)                 # D5 child system units first
                run(["systemctl", "--user", "stop", unit])
                st = read_state(spec_id) or {}
                if st.get("attempt_id") == attempt_id and st.get("status") in LIVE:
                    write_state(spec_id, {**st, "status": "interrupted",
                                          "error_class": "hang",
                                          "detail": "confirmed hang: no CPU/event/journal progress "
                                                    "across two consecutive health checks"})
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


# ============================================================= reconcile ======
def cmd_reconcile() -> None:
    """Session-start ritual (Gate 3 / CLAUDE.md): read state, inspect real units, mark drift."""
    reconciled = []
    for st in all_states():
        if st.get("status") not in LIVE:
            continue
        aid = st.get("attempt_id")
        spec_id = st.get("spec_id")
        unit = st.get("unit") or (unit_name(*parse_attempt_id(aid)) if aid else None)
        active = unit_active(unit) if unit else False
        if not active:
            write_state(spec_id, {**st, "status": "interrupted", "error_class": "interrupted",
                                  "detail": "reconcile: state was LIVE but unit is gone "
                                            "(orchestrator/box restart); resumable as a fresh "
                                            "attempt"})
            reconciled.append({"attempt_id": aid, "from": st.get("status"),
                               "to": "interrupted", "unit_active": False})
        else:
            reconciled.append({"attempt_id": aid, "status": st.get("status"),
                               "unit_active": True, "note": "still running"})
    print(json.dumps({"reconciled": reconciled,
                      "live_units": [u for u in _list_codex_units()]}, indent=2))


def _list_codex_units() -> list[str]:
    cp = run(["systemctl", "--user", "list-units", "codex-*", "--no-legend", "--plain"])
    return [ln.split()[0] for ln in (cp.stdout or "").splitlines() if ln.strip()]


# =============================================================== metrics ======
# ASSURANCE scorecard (holistic-review takeaway #2, SOL/Fable 2026-07-13): derive a trust/assurance
# picture from the provenance we already keep — NOT a vanity "autonomy %". Read-only; no side effects.
# The point is straight-through vs remediation vs escaped-defect signal, stratified by risk class, so
# the numbers can't be Goodharted into "look how autonomous we are".
def cmd_metrics() -> None:
    from collections import Counter

    per_spec = {}   # spec_id -> {risk, attempts:[(n,status,error_class,merged)], reviewer:[...], escalated:bool}
    quality_distribution = {dimension: Counter({score: 0 for score in range(1, 6)})
                            for dimension in QUALITY_DIMENSIONS}
    quality_scored_attempts = quality_skipped = 0
    quality_schema = json.loads(VERDICT_SCHEMA.read_text())["properties"]["quality"]
    quality_validator = Draft202012Validator(quality_schema)
    if ATTEMPTS.exists():
        for sd in sorted(ATTEMPTS.iterdir()):
            if not sd.is_dir():
                continue
            spec_id = sd.name
            try:
                risk = load_spec(spec_id).get("risk_class", "default") if spec_path(spec_id).exists() else "unknown"
            except SystemExit:
                risk = "unknown"
            rec = per_spec.setdefault(spec_id, {"risk": risk, "attempts": [], "reviewer": [], "escalated": False})
            for ad in sorted((q for q in sd.iterdir() if q.name.isdigit()), key=lambda q: int(q.name)):
                rp = ad / "result.json"
                if rp.exists():
                    try:
                        r = json.loads(rp.read_text())
                        rec["attempts"].append((int(ad.name), r.get("status"), r.get("error_class"),
                                                bool(r.get("merged"))))
                    except Exception:
                        pass
                rv = ad / "review.json"
                if rv.exists():
                    try:
                        v = json.loads(rv.read_text())
                        if v.get("verdict"):
                            rec["reviewer"].append(v["verdict"])
                        if v.get("schema_version") != "3" or not isinstance(v.get("quality"), dict):
                            quality_skipped += 1
                        elif list(quality_validator.iter_errors(v["quality"])):
                            quality_skipped += 1
                        else:
                            scores = {dimension: v["quality"][dimension]["score"]
                                      for dimension in QUALITY_DIMENSIONS}
                            for dimension, score in scores.items():
                                quality_distribution[dimension][score] += 1
                            quality_scored_attempts += 1
                    except Exception:
                        quality_skipped += 1
    if ESCALATIONS.exists():
        for p in ESCALATIONS.glob("*.json"):
            sid = p.name.split("-2")[0]  # SPEC-XXX-<ts>
            if sid in per_spec:
                per_spec[sid]["escalated"] = True

    err = Counter(); rev = Counter(); by_risk = {}
    specs_total = passed = merged = straight_through = needed_remediation = escalated = 0
    total_attempts = 0
    for sid, rec in per_spec.items():
        atts = rec["attempts"]
        if not atts:
            continue
        specs_total += 1
        total_attempts += len(atts)
        for _, st, ec, mg in atts:
            if ec:
                err[ec] += 1
        for v in rec["reviewer"]:
            rev[v] += 1
        merit = [a for a in atts if a[1] in MERIT_FAILURES]
        got_pass = any(a[1] == "passed_pr_opened" for a in atts)
        got_merge = any(a[3] for a in atts)
        passed += 1 if got_pass else 0
        merged += 1 if got_merge else 0
        # straight-through = passed on attempt 1 with no prior merit failure
        st_ok = got_pass and not merit and atts[0][1] == "passed_pr_opened"
        straight_through += 1 if st_ok else 0
        needed_remediation += 1 if len(merit) >= 1 and got_pass else 0
        escalated += 1 if rec["escalated"] else 0
        b = by_risk.setdefault(rec["risk"], {"specs": 0, "straight_through": 0, "merged": 0})
        b["specs"] += 1; b["straight_through"] += 1 if st_ok else 0; b["merged"] += 1 if got_merge else 0

    def pct(a, b): return round(100 * a / b, 1) if b else None
    out = {
        "generated": now(),
        "specs_with_attempts": specs_total,
        "total_attempts": total_attempts,
        "attempts_per_spec": round(total_attempts / specs_total, 2) if specs_total else None,
        "straight_through_rate_pct": pct(straight_through, specs_total),
        "needed_remediation_pct": pct(needed_remediation, specs_total),
        "escalation_rate_pct": pct(escalated, specs_total),
        "eventually_passed_pct": pct(passed, specs_total),
        "merged_pct": pct(merged, specs_total),
        "by_risk_class": {k: {**v, "straight_through_pct": pct(v["straight_through"], v["specs"]),
                              "merged_pct": pct(v["merged"], v["specs"])} for k, v in sorted(by_risk.items())},
        "failure_error_classes": dict(err.most_common()),
        "reviewer_verdicts": dict(rev.most_common()),
        "quality_advisory": True,
        "quality_advisory_note": "ADVISORY operator trend signal only; never used by any gate or merge decision.",
        "quality_score_distribution": {
            dimension: {str(score): quality_distribution[dimension][score]
                        for score in range(1, 6)}
            for dimension in QUALITY_DIMENSIONS
        },
        "quality_avg_by_dimension": {
            dimension: (round(sum(score * count for score, count in
                                  quality_distribution[dimension].items()) /
                              quality_scored_attempts, 1)
                        if quality_scored_attempts else None)
            for dimension in QUALITY_DIMENSIONS
        },
        "quality_scored_attempts": quality_scored_attempts,
        "quality_skipped": quality_skipped,
        "note": "Assurance signal, NOT a published autonomy KPI. Straight-through = passed on attempt 1 "
                "with no prior merit failure. Escaped-defect / reversion tracking requires post-merge "
                "data not yet collected (see holistic-review decision).",
    }
    print(json.dumps(out, indent=2))


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
    base_branch = lc.get("base_branch", "ready-for-main")
    base_sha = result.get("base_sha") or lc.get("base_sha")
    worker_commit = result.get("worker_commit")
    pr_url = result.get("pr_url")
    pr = _pr_number(pr_url)

    # Grant bounds (defense in depth; already enforced at launch, re-checked at the merge boundary).
    if base_branch == "main":
        die("main promotion is human-only; never auto-merged.", 12)
    if base_branch != grant.get("target_branch", "ready-for-main"):
        die(f"target branch {base_branch} != grant target; refuse.", 12)
    spec = load_spec(spec_id)
    if spec.get("risk_class") not in grant.get("allowed_risk_class", ["low"]):
        die(f"risk_class {spec.get('risk_class')} not in grant; refuse.", 12)
    if spec.get("needs_network", False) and not grant.get("needs_network_allowed", False):
        die("needs_network spec not permitted by grant; refuse.", 12)

    # PR state must match exactly what was reviewed.
    pv = run(["gh", "pr", "view", pr, "--json",
              "state,isDraft,headRefOid,baseRefName,mergeable,mergeStateStatus,statusCheckRollup"])
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
    """Repo-relative provenance paths for one spec (git add skips gitignored raw files)."""
    paths = [f"specs/{spec_id}.yaml"]
    paths += [str(p.relative_to(ROOT)) for p in APPROVALS.glob(f"{digest}*.json")]
    d = ATTEMPTS / spec_id
    if d.exists():
        paths.append(str(d.relative_to(ROOT)))
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
            f"approval(s), attempt evidence, and any escalations. Raw logs stay gitignored; "
            f"integrity provable via tracked raw-sha256.txt.")
        git("push", "-u", "origin", branch)
        pr = run(["gh", "pr", "create", "--base", "ready-for-main", "--head", branch,
                  "--title", f"provenance: {ids}",
                  "--body", "Auto-committed provenance (dispatch integrate, Gate 4 / "
                            "Level 1.5 grant). Spec + approvals + attempt evidence + "
                            "escalations; raw logs stay gitignored."], cwd=str(ROOT))
        if pr.returncode != 0:
            die(f"provenance PR create failed: {pr.stderr.strip()}", 20)
        pr_url = (pr.stdout or "").strip().splitlines()[-1]
        prn = _pr_number(pr_url)
        # Wait for a DEFINITIVE ci result. Before Actions picks the job up, `gh pr checks` can
        # print an "expected"/empty rollup that contains no "pending" — breaking on that merges
        # too early and the ruleset rejects it (observed live, provenance PR #19).
        for _ in range(30):
            ck = run(["gh", "pr", "checks", prn])
            outp = ((ck.stdout or "") + (ck.stderr or "")).lower()
            if re.search(r"\b(pass|fail)\b", outp):
                break
            time.sleep(10)
        mg = run(["gh", "pr", "merge", prn, "--merge", "--delete-branch"])
        if mg.returncode != 0:
            die(f"provenance PR #{prn} merge failed (left open for review): "
                f"{mg.stderr.strip()}", 20)
        return pr_url
    finally:
        git("checkout", "--quiet", "ready-for-main")
        git("pull", "--quiet", "--ff-only", "origin", "ready-for-main")


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
        ts = run(["./scripts/test"], cwd=str(ROOT))
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
        run(["git", "branch", "-D", f"codex/{aid}"], cwd=str(ROOT))
        run(["git", "push", "-q", "origin", "--delete", f"codex/{aid}"], cwd=str(ROOT))
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
    for name in ("status", "await", "cancel", "merge", "_run"):
        p = sub.add_parser(name)
        p.add_argument("attempt_id")
    ph = sub.add_parser("health")
    ph.add_argument("attempt_id")
    ph.add_argument("--minutes", type=int, default=HEALTH_INACTIVITY_MIN,
                    help="inactivity threshold before an alert (default 10)")
    sub.add_parser("reconcile")
    sub.add_parser("metrics")
    pi = sub.add_parser("integrate")
    pi.add_argument("attempt_ids", nargs="+")
    args = ap.parse_args()

    if args.cmd == "launch":
        cmd_launch(args.spec_id)
    elif args.cmd == "status":
        cmd_status(args.attempt_id)
    elif args.cmd == "await":
        cmd_await(args.attempt_id)
    elif args.cmd == "cancel":
        cmd_cancel(args.attempt_id)
    elif args.cmd == "merge":
        cmd_merge(args.attempt_id)
    elif args.cmd == "health":
        cmd_health(args.attempt_id, args.minutes)
    elif args.cmd == "reconcile":
        cmd_reconcile()
    elif args.cmd == "metrics":
        cmd_metrics()
    elif args.cmd == "integrate":
        cmd_integrate(args.attempt_ids)
    elif args.cmd == "_run":
        _run(args.attempt_id)


if __name__ == "__main__":
    main()
