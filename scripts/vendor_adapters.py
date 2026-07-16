#!/usr/bin/env python3
"""Vendor CLI mechanics for the bound-reviewer role (R73 Job 1). Adapters carry NO security or
policy decisions: the role envelope — neutral cwd outside the repo, per-invocation deadline,
nonzero-exit refusal before any parse, spec+diff+evidence-only prompt, verdict validation and
binding — lives in scripts/dispatch.py and is identical for every vendor. An adapter only knows
how to build its CLI's argv, shape the prompt for structured output, and read a verdict back.
Stdlib only. The reviewer-retirement failover is NOT adapter surface: it is Fable-specific by
design and dispatch.py gates it on the frozen reviewer vendor being claude.

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
        if obj is None and raw.startswith("```"):
            # Compatibility fallback: strip one leading ```/```json fence line and the trailing
            # fence, then retry. Anything else stays None → the gate fails closed upstream.
            body = raw.split("\n", 1)[1] if "\n" in raw else ""
            body = body.rsplit("```", 1)[0]
            try:
                obj = json.loads(body.strip())
            except Exception:
                obj = None
        return obj if isinstance(obj, dict) else None


_REVIEWERS = {"claude": ClaudeReviewer, "codex": CodexReviewer}


def get_reviewer_adapter(vendor):
    """The reviewer adapter for a declared vendor. Unknown vendors raise — the caller fails
    closed; nothing ever guesses a CLI."""
    if vendor not in _REVIEWERS:
        raise ValueError(f"no reviewer adapter for vendor {vendor!r} "
                         f"(known: {'/'.join(sorted(_REVIEWERS))})")
    return _REVIEWERS[vendor]()
