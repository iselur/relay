# AGENTS.md — conventions and commands

Referenced by [CLAUDE.md](CLAUDE.md), which holds the operating rules in terms of ROLES. This is the
only file that maps a role to a vendor — swapping a model is an edit here, never to the rulebook.

## Who plays which role (today)

| Role | Today | Note |
|---|---|---|
| owner | the human | approves specs, merges `main` |
| orchestrator | Claude Code on this box (Opus 4.8 high; Fable 5 default retired at owner direction 2026-07-15) | dispatches, reviews worker diffs, reports |
| worker | Codex CLI (`gpt-5.6-luna`) | research, drafts, implementation, tests (BUILD phase) |
| reviewer | whichever vendor did NOT author the work | never self-review, never same-vendor review |

## What this repo is

An orchestrator that dispatches worker jobs from schema-validated specs, checks the output (work
untouched → in scope → tests actually ran → cross-vendor review), and opens PRs the owner merges.

## Stack

- **Dispatcher:** Python 3 (`scripts/dispatch.py`), venv in `.venv/` (gitignored), deps pinned in
  `scripts/requirements.txt`. Thin bash wrapper `scripts/dispatch`.
- **Repo tests / CI:** bash. The test command is `./scripts/test` (runs `tests/*.sh`); the CI job
  is named exactly `ci` (required check on `main` and `ready-for-main` — never rename or add a matrix).

## Conventions

- Specs: `specs/SPEC-NNN.yaml`, schema `specs/spec.schema.json`. Immutable once approved; never
  regex-parsed. Approval files in `.orchestrator/approvals/<digest>.json`.
- Branches: worker branches `codex/SPEC-NNN-<attempt>`; PRs target `ready-for-main`; only the owner
  promotes `ready-for-main` → `main`. Both protected by ruleset.
- Worker isolation: the worker and the gate tests run as the `codex-worker` user in hardened systemd
  services; worktrees under `/srv/codexwork/worktrees`. Setup: `scripts/setup-worker-user.sh`.
  Proof: `tests/worker_isolation.sh`, `tests/worker_userns.sh`.
- Evidence: per-attempt under `.orchestrator/attempts/<id>/<n>/`; raw logs untracked, hashes
  tracked. It is an audit record (see SECURITY.md), not immutable.

## Codex on this box

- Model split: worker BUILD runs `gpt-5.6-luna` (dispatcher default); plans (`scripts/codex-plan`)
  and reviews (`scripts/review`) stay `gpt-5.6-sol`.
- Invocation: `codex exec -m <model per split above> -c model_reasoning_effort=high -c service_tier=priority
  --sandbox read-only --skip-git-repo-check - <prompt.txt` — prompt on stdin always (argv dies
  over 130KB). Web search: `-c tools.web_search=true`. The priority tier is a speed setting only.
- Consultations run detached (background or `systemd-run --user`) and may legitimately take hours —
  never a minute-scale timeout. Codex runs commands and reads the repo itself (its sandbox needs
  the `bwrap-userns-restrict` AppArmor profile loaded — without it every run dies at
  `bwrap: loopback: Failed RTM_NEWADDR`; proof: `tests/worker_userns.sh`). Inlining context is a
  choice now, not a requirement — the bound reviewer still gets spec + diff + evidence only, never
  a live checkout. The final answer is recoverable from the `--json` stream (last `agent_message`).
- Reviews of **Claude-authored** work go through `scripts/review` (reviewer = Codex; needs
  `--author`, refuses Codex-authored artifacts, counts rounds, refuses a fourth). Codex-authored work
  is reviewed by Claude — worker diffs by the bound reviewer in the dispatcher, plans in-session —
  under the same three-round cap.
- Plans go through `scripts/codex-plan`: `--small` (cap 40), default (cap 250), `--brief` (cap 400,
  and it refuses a brief missing any required section). Tiers and triggers: CLAUDE.md rule 5.
