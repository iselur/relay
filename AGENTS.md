# AGENTS.md — conventions and commands

Referenced by [CLAUDE.md](CLAUDE.md), which holds the operating rules in terms of ROLES. Humans read
the role table here; machines read `scripts/models.json` (roles, CLI aliases, vendor map).
A model swap is one edit there, never to the rulebook; vendors match by name pattern, so a new known-vendor model needs no config.

## Who plays which role (today)

| Role | Today | Note |
|---|---|---|
| owner | the human | approves specs, merges `main` |
| orchestrator | Claude Code on this box (Fable 5 high; the owner flips settings.json to Opus 4.8 at Fable retirement) | dispatches, reviews worker diffs, reports |
| worker | per `scripts/models.json`: Codex CLI (`gpt-5.6-luna`) detached, or a Claude subagent in-session | BUILD phase; a subagent BUILD is graded by `dispatch continue` |
| reviewer | per `scripts/models.json` (bound reviewer) | never reviews its own work |

Bound reviewer retirement: a retired reviewer model fails its review fail-closed; the owner flips
`scripts/models.json` by hand (owner decision 2026-07-17 — no automated failover).

## What this repo is

An orchestrator that dispatches worker jobs from schema-validated specs, checks the output (work
untouched → in scope → tests actually ran → bound review), and opens PRs the owner merges.

## Stack

- **Dispatcher:** Python 3 (`scripts/dispatch.py`), venv in `.venv/` (gitignored), deps pinned in
  `scripts/requirements.txt`. Thin bash wrapper `scripts/dispatch`.
- **Repo tests / CI:** bash. The test command is `./scripts/test` (runs `tests/*.sh`); the CI job
  is named exactly `ci` (required check on `main` and `ready-for-main` — never rename or add a matrix).

## Conventions

- Specs: `specs/SPEC-NNN.yaml`, schema `specs/spec.schema.json`. Immutable once approved; never
  regex-parsed. Approval files in `.orchestrator/approvals/<digest>.json`.
- Branches: worker branches `codex/SPEC-NNN-<attempt>`; PRs target `ready-for-main`; promotion to
  `main` is the owner's, or the orchestrator's under the CLAUDE.md grant. Both protected by ruleset.
- Worker isolation: external-CLI workers and the gate tests run as the `codex-worker` user in hardened
  systemd services; worktrees under `/srv/codexwork/worktrees`. Setup: `scripts/setup-worker-user.sh`.
  Proof: `tests/worker_isolation.sh`, `tests/worker_userns.sh`. Subagent workers: SECURITY.md.
- Evidence: per-attempt under `.orchestrator/attempts/<id>/<n>/`, untracked (gitignored). It is
  an on-box audit record (see SECURITY.md), not immutable and not repo content.

## Codex on this box

- Model split (from `scripts/models.json`): worker BUILD `gpt-5.6-luna`; plans and reviews `gpt-5.6-sol`.
- Invocation: `codex exec -m <model per split above> -c model_reasoning_effort=high
  --sandbox read-only --skip-git-repo-check - <prompt.txt` — prompt on stdin always (argv dies
  over 130KB). Web search: `-c tools.web_search=true`. Standard tier: never set `service_tier` (owner cost decision 2026-07-16).
- Consultations run detached (background or `systemd-run --user`) and may legitimately take hours —
  never a minute-scale timeout. Codex runs commands and reads the repo itself (its sandbox needs
  the `bwrap-userns-restrict` AppArmor profile loaded — without it every run dies at
  `bwrap: loopback: Failed RTM_NEWADDR`; proof: `tests/worker_userns.sh`). Inlining context is a
  choice now, not a requirement — the bound reviewer still gets spec + diff + evidence only, never
  a live checkout. The final answer is recoverable from the `--json` stream (last `agent_message`).
- Reviews of **Claude-authored** work go through `scripts/review` (reviewer = Codex; needs
  `--author`, refuses Codex-authored artifacts, counts rounds, refuses a sixth). Codex-authored work
  is reviewed by Claude — worker diffs by the bound reviewer in the dispatcher, plans in-session —
  under the same five-round cap.
- Plans go through `scripts/codex-plan --brief` (cap 400; refuses a brief missing any required
  section); the no-flag standard tier remains usable. Trigger: CLAUDE.md rule 5.
