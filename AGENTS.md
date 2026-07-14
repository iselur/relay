# AGENTS.md — conventions and commands

Referenced by [CLAUDE.md](CLAUDE.md), which holds the operating rules.

## What this repo is

An orchestrator that dispatches Codex worker jobs from schema-validated specs, checks their output
(work untouched → in scope → tests actually ran → cross-model review), and opens PRs the human
merges.

## Stack

- **Dispatcher:** Python 3 (`scripts/dispatch.py`), venv in `.venv/` (gitignored), deps pinned in
  `scripts/requirements.txt`. Thin bash wrapper `scripts/dispatch`.
- **Repo tests / CI:** bash. The test command is `./scripts/test` (runs `tests/*.sh`); the CI job
  is named exactly `ci` (required check on `main` and `integration` — never rename or add a matrix).

## Conventions

- Specs: `specs/SPEC-NNN.yaml`, schema `specs/spec.schema.json`. Immutable once approved; never
  regex-parsed. Approval files in `.orchestrator/approvals/<digest>.json`.
- Branches: worker branches `codex/SPEC-NNN-<attempt>`; PRs target `integration`; only the operator
  promotes `integration` → `main`. Both protected by ruleset.
- Worker isolation: the worker and the gate tests run as the `codex-worker` user in hardened
  systemd services; worktrees under `/srv/codexwork/worktrees`. One-time setup:
  `scripts/setup-worker-user.sh`. Proof: `tests/worker_isolation.sh`.
- Evidence: per-attempt under `.orchestrator/attempts/<id>/<n>/`; raw logs untracked, hashes
  tracked. It is an audit record (see SECURITY.md), not immutable.

## Codex on this box

- Invocation: `codex exec -m gpt-5.6-sol -c model_reasoning_effort=high -c service_tier=priority
  --sandbox read-only --skip-git-repo-check - <prompt.txt` — prompt on stdin always (argv dies
  over 130KB). Web search: `-c tools.web_search=true`. The priority tier is a speed setting only.
- Consultations run detached (background or `systemd-run --user`) and may legitimately take hours —
  never a minute-scale timeout. The Codex sandbox cannot read the repo on this host: inline the
  context. The final answer is recoverable from the `--json` stream (last `agent_message`).
- Adversarial reviews of **Claude-authored** work go through `scripts/review` (its reviewer is
  Codex; it requires `--author` and refuses Codex-authored artifacts, counts rounds per topic, and
  refuses a third round). Codex-authored work is reviewed by Claude — worker diffs by the bound
  reviewer in the dispatcher, plans in-session — under the same two-round cap.
  Plan drafts go through `scripts/codex-plan` — it refuses a plan body over 150 lines.
