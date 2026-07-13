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
MERIT_FAILURES = {"failed_test", "failed_review", "failed_scope", "failed_integrity"}
ESCALATIONS = ORCH / "escalations"

# Terminal vs live attempt statuses.
TERMINAL = {
    "passed_pr_opened", "failed_worker_error", "failed_integrity",
    "failed_scope", "failed_test", "failed_review", "interrupted", "error_launch",
    "spec_blocked", "stale_base", "failed_remediation_exhausted",
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
CODEX_PKG = OPERATOR_HOME / ".local/lib/node_modules/@openai/codex"  # bind-mounted RO to /opt/codex


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


def worktree_root() -> Path:
    return ISO_WORKTREES if isolation_available() else WORKTREES


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


# =============================================================== launch =======
def cmd_launch(spec_id: str) -> None:
    ctx = preflight(spec_id)
    spec, digest, approval = ctx["spec"], ctx["digest"], ctx["approval"]

    n = next_attempt(spec_id)
    # Gate 4: remediation budget + stop-early + high-risk per-dispatch approval. Dies (recording
    # failed_remediation_exhausted + escalation) if this launch is not permitted.
    remediation = remediation_preflight(spec_id, spec, digest, n)
    attempt_id = f"{spec_id}-{n}"
    att_dir = ATTEMPTS / spec_id / str(n)
    (att_dir / "raw").mkdir(parents=True, exist_ok=True)

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
        git("fetch", "--quiet", "origin", approval.get("base_branch", "integration"))
        base_sha = git("rev-parse", f"origin/{approval.get('base_branch', 'integration')}")
        branch = f"codex/{attempt_id}"
        iso = isolation_available()
        wt = worktree_root() / attempt_id
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
        "base_branch": approval.get("base_branch", "integration"),
        "worktree": str(wt), "worker_model": approval.get("worker_model", "gpt-5.6-sol"),
        "worker_effort": approval.get("worker_reasoning_effort", "high"),
        "reviewer_model": approval.get("reviewer_model", "claude-fable-5"),
        "reviewer_effort": approval.get("reviewer_effort", "high"),
        "test_command": spec["test_command"], "approved_scope": approval["approved_scope"],
        "hard_ceiling_hours": ceiling_h, "remediation": remediation,
        "isolation": iso, "worker_unit": f"codex-worker-{attempt_id}",
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

    iso = lc.get("isolation", False)
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
            argv = ["/usr/bin/node", "/opt/codex/bin/codex.js", *codex_args,
                    "-s", "danger-full-access", prompt]
            wc = isolated_run(
                lc["worker_unit"], argv, cwd=str(wt),
                rw_paths=[str(wt), str(WORKER_HOME / ".codex")],
                private_network=False, ceiling_s=ceiling_s, stdout=ev, stderr=er,
                binds=[(str(CODEX_PKG), "/opt/codex")])
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
               detail=f"worker error class={ec}")

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
    if iso:
        with open(att / "test.log", "w") as tl:
            tcp = isolated_run(
                lc["test_unit"], ["bash", "-c", lc["test_command"]], cwd=str(wt),
                rw_paths=[str(wt)], private_network=True, ceiling_s=ceiling_s,
                stdout=tl, stderr=subprocess.STDOUT)
        test_rc = tcp.returncode
    else:
        tc = run(["bash", "-c", lc["test_command"]], cwd=str(wt))
        (att / "test.log").write_text((tc.stdout or "") + (tc.stderr or ""))
        test_rc = tc.returncode
    if test_rc != 0:
        finish("failed_test", ERR_TEST, worker_commit=worker_commit, test_exit=test_rc)

    # --- step 8: reviewer (bound, fail-closed) --------------------------------
    verdict, vraw = review(att, spec_id, lc, worker_commit)
    atomic_write(att / "review.json", json.dumps(verdict, indent=2) if verdict else "{}")
    if not verdict or verdict.get("verdict") != "PASS":
        finish("failed_review", ERR_REVIEW, worker_commit=worker_commit,
               review_verdict=(verdict or {}).get("verdict", "malformed"))

    # --- step 8.5: stale-base guard (Gate 3 part 3 — parallelism safety) -------
    # With MAX_PARALLEL>1 a sibling attempt can integrate while this one runs, advancing the base
    # branch. This attempt was reviewed and tested against base_sha; integrating it onto a moved
    # base would land a combination no gate ever saw. Refuse to push. The orchestrator re-launches
    # a FRESH attempt off the new base (all gates re-run) — never a hand-rebase of a reviewed
    # worktree (that would carry a stale review verdict). This is the last check before the attempt
    # becomes visible, so the base cannot move between the check and the push in a way that matters.
    base_branch = lc.get("base_branch", "integration")
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


# ================================================================= merge =======
# Plan-scoped autonomy (Level 1.5, ratified by the operator 2026-07-13). The orchestrator may merge an
# attempt's PR to `integration` WITHOUT a per-PR human click — but ONLY through this fail-closed
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
    """Auto-merge a PASSED attempt's PR to integration under the AUTONOMY grant. Fail-closed:
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
    base_branch = lc.get("base_branch", "integration")
    base_sha = result.get("base_sha") or lc.get("base_sha")
    worker_commit = result.get("worker_commit")
    pr_url = result.get("pr_url")
    pr = _pr_number(pr_url)

    # Grant bounds (defense in depth; already enforced at launch, re-checked at the merge boundary).
    if base_branch == "main":
        die("main promotion is human-only; never auto-merged.", 12)
    if base_branch != grant.get("target_branch", "integration"):
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
    integration tip only moves when no sibling attempt merge could go stale because of it."""
    branch = f"orch/prov-{'-'.join(s.replace('SPEC-', '') for s in spec_ids)}"
    git("checkout", "--quiet", "integration")
    git("pull", "--quiet", "--ff-only", "origin", "integration")
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
        pr = run(["gh", "pr", "create", "--base", "integration", "--head", branch,
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
        git("checkout", "--quiet", "integration")
        git("pull", "--quiet", "--ff-only", "origin", "integration")


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

    git("checkout", "--quiet", "integration")
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
        git("pull", "--quiet", "--ff-only", "origin", "integration")
        ts = run(["./scripts/test"], cwd=str(ROOT))
        if ts.returncode != 0:
            path = escalate(sid, f"post-merge suite FAILED on integration after {aid} — "
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
    elif args.cmd == "integrate":
        cmd_integrate(args.attempt_ids)
    elif args.cmd == "_run":
        _run(args.attempt_id)


if __name__ == "__main__":
    main()
