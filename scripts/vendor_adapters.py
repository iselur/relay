#!/usr/bin/env python3
"""Vendor CLI mechanics for the bound-reviewer and worker roles (R73 Jobs 1-3). Adapters carry
NO security or policy decisions: the role envelopes — reviewer: neutral cwd outside the repo,
per-invocation deadline, nonzero-exit refusal before any parse, spec+diff+evidence-only prompt,
verdict validation and binding; worker: runtime vetting/pinning, the single attempt deadline,
path-safety, commit packaging, and every gate — live in scripts/dispatch.py. The worker
GRADING half is identical for every vendor; the BUILD envelope differs by the adapter's
declared mode: external-cli BUILDs run isolated under the worker role envelope, subagent
BUILDs run inside the orchestrator session's trust domain (SECURITY.md). An adapter only knows
how to build its CLI's argv, shape its I/O, and read the output back. Stdlib only. The
reviewer-retirement failover is NOT adapter surface: it is Fable-specific by design and
dispatch.py gates it on the frozen reviewer vendor being claude.

Verified mechanics (R73 probe evidence, 2026-07-16, .orchestrator/evidence/r73-probes.md):
- claude: `-p --output-format json` emits ONE JSON envelope; the verdict is a JSON string in
  its "result" field (double parse). Schema enforced inline via --json-schema.
- codex: `exec --output-schema <FILE> -` (prompt on stdin, no --json) exits 0 with the BARE
  schema-conforming JSON object on stdout — no fences observed; fence-stripping is a
  compatibility fallback only.
- kimi: top-level `-p` one-shot (no exec subcommand); the prompt is argv-ONLY — no stdin or
  prompt-file transport exists, so an oversized request is refused before invocation, never
  truncated. `-m` takes the CLI's provider alias (cli_aliases required), `--output-format
  stream-json` emits one JSON object per line and the final assistant message is the last
  {"role":"assistant"} line. No CLI-enforced schema: verdict JSON is prompt-requested and
  parsed with the same fail-closed discipline as codex. (kimi probe evidence, 2026-07-16,
  .orchestrator/evidence/kimi-probes.md)
"""

import json


def _strict_json_object(raw):
    """The fail-closed parse for prompt-requested structured output, shared by every vendor
    without CLI schema enforcement: a bare JSON object, or EXACTLY one ```/```json fence pair.
    Anything else is None and the gate fails closed upstream."""
    raw = (raw or "").strip()
    try:
        obj = json.loads(raw)
    except Exception:
        obj = None
    if obj is None:
        # Compatibility fallback (R73 round-1 review: the loose strip was fail-open — it
        # accepted a missing closing fence, arbitrary fence labels, and dropped prose after
        # the last fence, so a PASS object followed by contradictory prose still extracted).
        # Accept EXACTLY one ```/```json fence pair: opener is the first line, the closer is
        # the LAST line, the body alone must parse. Anything else — no closer, another
        # label, trailing content — stays None and the gate fails closed upstream.
        lines = raw.splitlines()
        if (len(lines) >= 3 and lines[0].strip() in ("```", "```json")
                and lines[-1].strip() == "```"):
            try:
                obj = json.loads("\n".join(lines[1:-1]))
            except Exception:
                obj = None
    return obj if isinstance(obj, dict) else None


class ClaudeReviewer:
    """Today's shipped claude mechanics, verbatim — flags per B16 hardening."""

    def build_argv(self, model_id, effort, schema_obj, cli_aliases, schema_path, request=None):
        # request is accepted for signature uniformity (kimi carries the prompt in argv) and
        # ignored: the claude prompt rides on stdin.
        return [
            "claude", "-p", "--output-format", "json", "--json-schema", json.dumps(schema_obj),
            "--model", cli_aliases.get(model_id, model_id),
            "--effort", effort,
            "--safe-mode", "--tools", "", "--strict-mcp-config", "--no-session-persistence",
            "--disallowedTools", "Read", "Grep", "Glob", "Bash", "Write", "Edit", "NotebookEdit",
            "WebFetch", "WebSearch", "Task", "--permission-mode", "manual",
        ]

    def reviewer_prompt(self, req, schema_obj):
        return req  # schema rides in argv; the prompt is untouched

    def extract_verdict(self, stdout):
        try:
            verdict = json.loads(json.loads(stdout)["result"])
        except Exception:
            return None
        return verdict if isinstance(verdict, dict) else None


class CodexReviewer:
    """codex exec with structural output via --output-schema (probe-proven bare JSON)."""

    def build_argv(self, model_id, effort, schema_obj, cli_aliases, schema_path, request=None):
        # request is accepted for signature uniformity (kimi carries the prompt in argv) and
        # ignored: the codex prompt rides on stdin ("-").
        return [
            "codex", "exec", "-m", cli_aliases.get(model_id, model_id),
            "-c", f"model_reasoning_effort={effort}",
            "--sandbox", "read-only", "--skip-git-repo-check",
            "--output-schema", str(schema_path),
            "-",  # prompt on stdin — production-proven by scripts/review
        ]

    def reviewer_prompt(self, req, schema_obj):
        return (req + "\n\nOutput ONLY one JSON object conforming exactly to this schema — no "
                "markdown, no code fences, no prose before or after:\n"
                + json.dumps(schema_obj, indent=2))

    def extract_verdict(self, stdout):
        return _strict_json_object(stdout)


KIMI_ARGV_PROMPT_LIMIT = 120_000   # UTF-8 bytes: conservative headroom under Linux's ~128KiB
                                   # single-argument wall (MAX_ARG_STRLEN), the probe-D E2BIG line


class KimiReviewer:
    """kimi-code one-shot review (probe evidence, .orchestrator/evidence/kimi-probes.md). The
    CLI has no stdin transport, so the SHAPED request itself must ride in argv: build_argv
    takes it as `request`, passed by dispatch.py's review() (kimi slice 3); a missing request
    refuses rather than invoking a promptless CLI.
    A request over the argv wall is refused before invocation, never truncated (owner decision
    2026-07-16). No effort flag: K3 carries kimi's own effort model (only "max"), never
    codex's model_reasoning_effort. No auto-approval flag either: without -y kimi cannot write
    or exec (probe F), which is exactly the confinement a one-shot reviewer in the
    dispatcher's neutral cwd should keep."""

    def build_argv(self, model_id, effort, schema_obj, cli_aliases, schema_path, request=None):
        if request is None:
            raise ValueError("kimi reviewer requires the shaped request in argv (request=): "
                             "the CLI has no stdin or prompt-file transport; fail closed")
        size = len(request.encode("utf-8"))
        if size > KIMI_ARGV_PROMPT_LIMIT:
            raise ValueError(f"kimi reviewer request is {size} UTF-8 bytes, over the "
                             f"{KIMI_ARGV_PROMPT_LIMIT}-byte argv guard (probe D E2BIG wall): "
                             f"refused before invocation, never truncated")
        model = cli_aliases.get(model_id) if isinstance(cli_aliases, dict) else None
        # Round-2 review: truthiness alone accepted an identity alias (the raw relay id
        # laundered through the map) and non-string values straight into argv — the alias
        # must be a non-empty STRING distinct from the relay model id.
        if not isinstance(model, str) or not model.strip() or model == model_id:
            raise ValueError(f"kimi reviewer requires a distinct CLI provider alias for "
                             f"{model_id!r} (probe A: the kimi CLI accepts its own aliases, "
                             f"never relay model ids); the frozen cli_aliases carries "
                             f"{model!r}; fail closed")
        return ["kimi", "-p", request, "-m", model, "--output-format", "stream-json"]

    def reviewer_prompt(self, req, schema_obj):
        return (req + "\n\nOutput ONLY one JSON object conforming exactly to this schema — no "
                "markdown, no code fences, no prose before or after:\n"
                + json.dumps(schema_obj, indent=2))

    def extract_verdict(self, stdout):
        # Round-1 review (major): taking the last WELL-FORMED assistant string let an earlier
        # PASS survive trailing malformed JSON, non-string content, or raw prose — a stale
        # verdict extracted from a stream that no longer ends in one. The verdict source is the
        # content of the LAST assistant event only while the stream stays valid behind it: any
        # malformed line, non-object line, or assistant event with non-string content
        # invalidates what came before; only a subsequent VALID assistant event supersedes the
        # damage. Whitespace-only lines are neutral; other non-assistant JSON objects are
        # ordinary stream events and leave the verdict source untouched.
        content = None
        for line in (stdout or "").splitlines():
            if not line.strip():
                continue
            try:
                e = json.loads(line)
            except Exception:
                content = None
                continue
            if not isinstance(e, dict):
                content = None
                continue
            if e.get("role") == "assistant":
                c = e.get("content")
                content = c if isinstance(c, str) else None
        return _strict_json_object(content) if content is not None else None


class CodexWorker:
    """Codex worker CLI mechanics, verbatim from the pre-adapter dispatcher (R73 Job 2:
    behavior-identical refactor). The adapter carries argv construction, the unisolated-path
    environment, output recovery, and error classification ONLY — see the module docstring for
    what stays in dispatch.py. The model id reaches the CLI exactly as frozen in launch.json:
    the worker path has never alias-translated it and no codex model declares a cli_alias.
    cli_aliases is accepted for signature uniformity with vendors whose worker CLI needs the
    alias (kimi) and deliberately IGNORED here — the verbatim contract stands."""

    mode = "external-cli"   # detached CLI process under the worker role envelope (D5)

    def build_argv(self, model_id, effort, worktree, prompt, isolated,
                   argv_prefix=None, last_message_path=None, cli_aliases=None):
        args = ["exec", "--cd", str(worktree), "-m", model_id,
                "-c", f"model_reasoning_effort={effort}",
                "--skip-git-repo-check", "--json"]
        if isolated:
            # Codex's own sandbox is OFF (-s danger-full-access): it won't construct under the
            # bind-mounted UID; the hardened service confines the worker instead (D5). The
            # argv prefix is the runtime dispatch.py vetted and pinned at launch.
            # --output-last-message is unavailable (the worker can't write the operator-side
            # evidence dir); recover_last_message reads the --json event stream instead.
            return [*(argv_prefix or []), *args, "-s", "danger-full-access", prompt]
        # Unisolated fallback (fresh box / CI): Codex's bwrap sandbox stays ON and the final
        # message lands straight in the evidence dir (same user, reachable). The deadline
        # timeout prefix is role policy and stays in dispatch.py, prepended by the caller.
        return ["codex", *args, "--sandbox", "workspace-write",
                "--output-last-message", str(last_message_path), prompt]

    def worker_env(self, operator_home, operator_user):
        """Scrubbed environment for the UNISOLATED path only. The isolated service environment
        is role envelope and stays owned by dispatch.py's isolated_run."""
        return {"HOME": str(operator_home), "USER": operator_user, "LOGNAME": operator_user,
                "PATH": f"{operator_home}/.local/bin:/usr/bin:/bin",
                "CODEX_HOME": f"{operator_home}/.codex", "TERM": "dumb", "LANG": "C.UTF-8"}

    def iso_rw_paths(self, worker_home):
        """Codex needs its own auth/state dir writable inside the hardened service."""
        return [str(worker_home / ".codex")]

    def iso_env_extra(self, worker_home):
        """Vendor auth/state variables for the ISOLATED service (round-1 review: these are
        adapter surface, not role envelope). Value-identical to codex's default state dir
        under HOME=worker_home; stated explicitly so a vendor whose default differs (Job 3)
        has a hook instead of a hardcode in isolated_run."""
        return {"CODEX_HOME": str(worker_home / ".codex")}

    def runtime(self, resolve_codex_runtime):
        """Delegates to dispatch.py's module-level worker_codex_runtime (injected by the
        caller): runtime resolution and vetting are trust machinery, exercised directly by
        tests/codex_runtime.sh — the adapter only names WHICH resolver its vendor uses."""
        return resolve_codex_runtime()

    def recover_last_message(self, raw_dir, isolated):
        """The worker's final message: from the --json event stream when isolated (the worker
        cannot write the operator-side evidence dir), else from the file the CLI wrote."""
        if isolated:
            msg = ""
            try:
                for line in (raw_dir / "events.jsonl").read_text().splitlines():
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
        p = raw_dir / "worker-last-message.txt"
        return p.read_text() if p.exists() else ""

    def classify_error(self, exit_code, stderr, raw_dir):
        """A structured error class, or None when the worker ran to completion. Speaks the
        dispatcher's recorded error-class vocabulary verbatim: quota_rate_limit, auth,
        sandbox_denial, worker_nonzero — dispatch.py refuses to record anything else."""
        low = stderr.lower()
        if "429" in stderr or "too many requests" in low or "rate limit" in low:
            return "quota_rate_limit"
        if "not logged in" in low or "401" in stderr or "403" in stderr or "unauthorized" in low:
            return "auth"
        # A worker killed by RuntimeMaxSec: unit terminated; codex exit is nonzero/none.
        saw_turn_complete = False
        try:
            for line in (raw_dir / "events.jsonl").read_text().splitlines():
                if '"type":"turn.completed"' in line or '"turn.completed"' in line:
                    saw_turn_complete = True
        except Exception:
            pass
        if not saw_turn_complete and exit_code != 0:
            # Sandbox failures surface in the final message / stderr.
            if "sandbox" in low or "operation not permitted" in low or "bwrap" in low:
                return "sandbox_denial"
            return "worker_nonzero"
        return None


class ClaudeSubagentWorker:
    """Claude worker mechanics for SUBAGENT mode (R73 Job 3, owner simplification 2026-07-16):
    there is NO worker CLI. Anthropic's 2026 ToS keeps Claude execution inside the operator
    context, so the BUILD phase runs as a subagent of the live orchestrator session — the
    orchestrator launches `dispatch launch`, runs the subagent itself on the launch-written
    worker prompt inside the attempt worktree, writes the subagent's final message to
    raw/worker-last-message.txt, then hands grading to `dispatch continue`. This adapter
    therefore carries only the surface the SHARED grading half consumes; there is no argv,
    env, or runtime surface to carry. The role envelope for this mode is the orchestrator
    trust domain itself (SECURITY.md), plus every unchanged grading gate."""

    mode = "subagent"   # BUILD inside the orchestrator session; grading via dispatch continue

    def recover_last_message(self, raw_dir, isolated):
        """The subagent's final message, written by the orchestrator before continue. Absence
        refuses upstream (dispatch continue), so this read stays total here."""
        p = raw_dir / "worker-last-message.txt"
        return p.read_text() if p.exists() else ""

    def classify_error(self, exit_code, stderr, raw_dir):
        """Always completion: a subagent BUILD that failed is cancelled by the orchestrator
        (`dispatch cancel`), never mis-classified into the CLI error vocabulary — there is no
        CLI exit code or stderr to classify."""
        return None


class KimiWorker:
    """kimi-code worker CLI mechanics (probe evidence, .orchestrator/evidence/kimi-probes.md):
    top-level -p prompt (no exec subcommand), -m takes the CLI's provider alias — the one
    worker whose CLI does NOT accept the relay model id verbatim, so build_argv consumes the
    frozen cli_aliases (dispatch.py passes them in the owner-gated slice 3) — stream-json
    output, and -y auto-approval (kimi has no inner sandbox and its permission model otherwise
    blocks on interactive approval, probe F; the hardened systemd service is the sole
    confinement). No effort flag: K3 supports only kimi's own "max". State home is fixed at
    $HOME/.kimi-code (no KIMI_HOME-style override exists, probe A), so the isolated service
    needs only that path writable and no extra environment. UNISOLATED runs are refused, fail
    closed: the CLI cannot set its own working directory (no --cd — the worker would run in
    the dispatcher's cwd, not the worktree) and has no inner sandbox to fall back on (codex's
    unisolated fallback keeps bwrap ON; kimi would run with no confinement at all)."""

    mode = "external-cli"   # detached CLI process under the worker role envelope (D5)

    def build_argv(self, model_id, effort, worktree, prompt, isolated,
                   argv_prefix=None, last_message_path=None, cli_aliases=None):
        if not isolated:
            raise ValueError("kimi worker has no unisolated mode: the CLI cannot set its own "
                             "working directory (no --cd) and has no inner sandbox (probes "
                             "B/F); the hardened service is the only confinement — fail closed")
        model = cli_aliases.get(model_id) if isinstance(cli_aliases, dict) else None
        # Round-2 review: truthiness alone accepted an identity alias (the raw relay id
        # laundered through the map) and non-string values straight into argv — the alias
        # must be a non-empty STRING distinct from the relay model id.
        if not isinstance(model, str) or not model.strip() or model == model_id:
            raise ValueError(f"kimi worker requires a distinct CLI provider alias for "
                             f"{model_id!r} (probe A: the kimi CLI accepts its own aliases, "
                             f"never relay model ids); the frozen cli_aliases carries "
                             f"{model!r}; fail closed")
        return [*(argv_prefix or []), "-p", prompt,
                "-m", model, "--output-format", "stream-json", "-y"]

    def worker_env(self, operator_home, operator_user):
        """Scrubbed environment for the UNISOLATED path, kept total because dispatch.py builds
        the env before argv — build_argv then refuses the unisolated run itself. No CODEX_HOME
        analog exists: kimi's state home is fixed at $HOME/.kimi-code."""
        return {"HOME": str(operator_home), "USER": operator_user, "LOGNAME": operator_user,
                "PATH": f"{operator_home}/.local/bin:/usr/bin:/bin",
                "TERM": "dumb", "LANG": "C.UTF-8"}

    def iso_rw_paths(self, worker_home):
        """kimi needs its fixed state home writable inside the hardened service (session state
        and logs live beside the worker's copied credential)."""
        return [str(worker_home / ".kimi-code")]

    def iso_env_extra(self, worker_home):
        """No vendor environment at all: kimi has no KIMI_HOME-style override (probe A) — the
        fixed $HOME/.kimi-code resolves from the service's HOME=worker_home."""
        return {}

    def runtime(self, resolve_runtime):
        """Delegates to the module-level runtime resolver dispatch.py injects (the owner-gated
        slice 3 adds worker_kimi_runtime and vendor-selects it): runtime resolution and vetting
        are trust machinery and stay in dispatch.py; the adapter only names the seam."""
        return resolve_runtime()

    def recover_last_message(self, raw_dir, isolated):
        """The worker's final message: the last assistant line with string content in the
        stream-json capture, skipping malformed lines — MESSAGE RECOVERY with the same
        leniency as codex's event-stream read, not a gate (the reviewer's verdict extraction
        is the strict one). kimi has no --output-last-message, so BOTH paths read the
        captured stream (stdout lands in events.jsonl either way)."""
        msg = ""
        try:
            for line in (raw_dir / "events.jsonl").read_text().splitlines():
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if (isinstance(e, dict) and e.get("role") == "assistant"
                        and isinstance(e.get("content"), str)):
                    msg = e["content"]
        except Exception:
            pass
        return msg

    def classify_error(self, exit_code, stderr, raw_dir):
        """A structured error class, or None when the worker ran to completion — the
        dispatcher's recorded vocabulary verbatim. Probe E signatures: auth/membership errors
        are explicit; a rate-limit signature was unobserved, so the quota substrings stay
        best-effort; config.invalid and everything else unmatched is worker_nonzero. kimi has
        no inner sandbox, so no sandbox_denial mapping exists — a hardened-service denial
        surfaces as worker_nonzero."""
        if exit_code == 0:
            return None
        low = stderr.lower()
        if "429" in stderr or "too many requests" in low or "rate limit" in low:
            return "quota_rate_limit"
        if ("membership" in low or "not logged in" in low or "unauthorized" in low
                or "401" in stderr or "403" in stderr):
            return "auth"
        return "worker_nonzero"


_REVIEWERS = {"claude": ClaudeReviewer, "codex": CodexReviewer, "kimi": KimiReviewer}
_WORKERS = {"claude": ClaudeSubagentWorker, "codex": CodexWorker, "kimi": KimiWorker}


def get_reviewer_adapter(vendor):
    """The reviewer adapter for a declared vendor. Unknown vendors raise — the caller fails
    closed; nothing ever guesses a CLI."""
    if vendor not in _REVIEWERS:
        raise ValueError(f"no reviewer adapter for vendor {vendor!r} "
                         f"(known: {'/'.join(sorted(_REVIEWERS))})")
    return _REVIEWERS[vendor]()


def worker_vendors():
    """Vendors with a registered worker adapter — the resolver refuses any other worker vendor
    at launch, before side effects."""
    return sorted(_WORKERS)


def worker_mode(vendor):
    """The execution mode a vendor's worker runs under: 'external-cli' (detached CLI process in
    the worker role envelope) or 'subagent' (BUILD inside the orchestrator session, grading via
    `dispatch continue`). Unknown vendors raise — the caller fails closed."""
    return get_worker_adapter(vendor).mode


def get_worker_adapter(vendor):
    """The worker adapter for a declared vendor. Unknown vendors raise — the caller fails
    closed; nothing ever guesses a CLI."""
    if vendor not in _WORKERS:
        raise ValueError(f"no worker adapter for vendor {vendor!r} "
                         f"(known: {'/'.join(sorted(_WORKERS))})")
    return _WORKERS[vendor]()
