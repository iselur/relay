# AGENTS.md — conventions and commands

Referenced by [CLAUDE.md](CLAUDE.md), which holds the operating rules in terms of ROLES. Humans read
the role table here; machines read the key in each row's "set in" column — `roles.*` live in
`scripts/models.json`, and a model added there also adds its vendor_map line.

## Who plays which role

| Role | Set in | Note |
|---|---|---|
| owner | — | approves specs, merges `main` |
| orchestrator | `~/.claude/settings.json` → `model` | Claude Code on this box; dispatches, reviews worker diffs and spec-author plans, reports |
| utility_subagent | `~/.claude/settings.json` → `env.CLAUDE_CODE_SUBAGENT_MODEL` | in-session search and exploration; the BUILD receipt records the harness pin and `dispatch continue` requires it |
| spec_author | `roles.spec_author` | writes briefs via `scripts/codex-plan`, which invokes codex and kimi only — a claude spec_author passes validation, then codex-plan refuses it |
| worker | approval pin → `roles.worker` | BUILD phase: a detached external CLI, or an in-session Claude subagent graded by `dispatch continue` |
| bound_reviewer | approval pin → `roles.bound_reviewer` | reviews worker diffs, never its own work; a retired reviewer fails closed and the owner updates the default by hand (2026-07-17 — no automated failover) |
| orchestrator_artifact_reviewer | `roles.orchestrator_artifact_reviewer` | cross-checks orchestrator-authored artifacts via `scripts/review`; not invoked by `dispatch.py` |
| — dead keys — | `roles.orchestrator`, `roles.utility_subagent` | validated, never routed; the live values are the `settings.json` rows above. Deleting them fails config validation |

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

- Invocation: `codex exec -m <model per the role table> -c model_reasoning_effort=high
  --sandbox read-only --skip-git-repo-check - <prompt.txt` — prompt on stdin always (argv dies
  over 130KB). Web search: `-c tools.web_search=true`. Standard tier: never set `service_tier` (owner cost decision 2026-07-16).
- Consultations run detached (background or `systemd-run --user`) and may legitimately take hours —
  never a minute-scale timeout. Codex runs commands and reads the repo itself (its sandbox needs
  the `bwrap-userns-restrict` AppArmor profile loaded — without it every run dies at
  `bwrap: loopback: Failed RTM_NEWADDR`; proof: `tests/worker_userns.sh`). Inlining context is a
  choice now, not a requirement — the bound reviewer still gets spec + diff + evidence only, never
  a live checkout. The final answer is recoverable from the `--json` stream (last `agent_message`).
- `scripts/review` requires recorded provenance (`--author` must agree with it), refuses same-vendor
  review, counts rounds, and refuses a sixth. Who reviews whom follows the role table.
- Plans go through `scripts/codex-plan --brief` (cap 400; refuses a brief missing any required
  section); the no-flag standard tier remains usable. Trigger: CLAUDE.md rule 5.
