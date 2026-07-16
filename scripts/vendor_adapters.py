#!/usr/bin/env python3
"""Vendor CLI mechanics for the bound-reviewer and worker roles (R73 Jobs 1-2). Adapters carry
NO security or policy decisions: the role envelopes — reviewer: neutral cwd outside the repo,
per-invocation deadline, nonzero-exit refusal before any parse, spec+diff+evidence-only prompt,
verdict validation and binding; worker: isolation, runtime vetting/pinning, the single attempt
deadline, path-safety, commit packaging, and every gate — live in scripts/dispatch.py and are
identical for every vendor. An adapter only knows how to build its CLI's argv, shape its I/O,
and read the output back. Stdlib only. The reviewer-retirement failover is NOT adapter surface:
it is Fable-specific by design and dispatch.py gates it on the frozen reviewer vendor being
claude.

Verified mechanics (R73 probe evidence, 2026-07-16, .orchestrator/evidence/r73-probes.md):
- claude: `-p --output-format json` emits ONE JSON envelope; the verdict is a JSON string in
  its "result" field (double parse). Schema enforced inline via --json-schema.
- codex: `exec --output-schema <FILE> -` (prompt on stdin, no --json) exits 0 with the BARE
  schema-conforming JSON object on stdout — no fences observed; fence-stripping is a
  compatibility fallback only.
"""

import json


class ClaudeReviewer:
    """Today's shipped claude mechanics, verbatim — flags per B16 hardening."""

    def build_argv(self, model_id, effort, schema_obj, cli_aliases, schema_path):
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

    def build_argv(self, model_id, effort, schema_obj, cli_aliases, schema_path):
        return [
            "codex", "exec", "-m", cli_aliases.get(model_id, model_id),
            "-c", f"model_reasoning_effort={effort}", "-c", "service_tier=priority",
            "--sandbox", "read-only", "--skip-git-repo-check",
            "--output-schema", str(schema_path),
            "-",  # prompt on stdin — production-proven by scripts/review
        ]

    def reviewer_prompt(self, req, schema_obj):
        return (req + "\n\nOutput ONLY one JSON object conforming exactly to this schema — no "
                "markdown, no code fences, no prose before or after:\n"
                + json.dumps(schema_obj, indent=2))

    def extract_verdict(self, stdout):
        raw = (stdout or "").strip()
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


class CodexWorker:
    """Codex worker CLI mechanics, verbatim from the pre-adapter dispatcher (R73 Job 2:
    behavior-identical refactor). The adapter carries argv construction, the unisolated-path
    environment, output recovery, and error classification ONLY — see the module docstring for
    what stays in dispatch.py. The model id reaches the CLI exactly as frozen in launch.json:
    the worker path has never alias-translated it and no codex model declares a cli_alias;
    alias handling joins this surface only when a vendor's worker CLI needs it."""

    def build_argv(self, model_id, effort, worktree, prompt, isolated,
                   argv_prefix=None, last_message_path=None):
        args = ["exec", "--cd", str(worktree), "-m", model_id,
                "-c", f"model_reasoning_effort={effort}", "-c", "service_tier=priority",
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


_REVIEWERS = {"claude": ClaudeReviewer, "codex": CodexReviewer}
_WORKERS = {"codex": CodexWorker}


def get_reviewer_adapter(vendor):
    """The reviewer adapter for a declared vendor. Unknown vendors raise — the caller fails
    closed; nothing ever guesses a CLI."""
    if vendor not in _REVIEWERS:
        raise ValueError(f"no reviewer adapter for vendor {vendor!r} "
                         f"(known: {'/'.join(sorted(_REVIEWERS))})")
    return _REVIEWERS[vendor]()


def worker_vendors():
    """Vendors with a registered worker adapter — the resolver refuses any other worker vendor
    at launch, before side effects (claude joins in R73 Job 3 with the subagent runtime)."""
    return sorted(_WORKERS)


def get_worker_adapter(vendor):
    """The worker adapter for a declared vendor. Unknown vendors raise — the caller fails
    closed; nothing ever guesses a CLI."""
    if vendor not in _WORKERS:
        raise ValueError(f"no worker adapter for vendor {vendor!r} "
                         f"(known: {'/'.join(sorted(_WORKERS))})")
    return _WORKERS[vendor]()
