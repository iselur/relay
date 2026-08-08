# AGENTS.md — conventions and commands

**Before any work read and follow [CLAUDE.md](CLAUDE.md): the whole operating rulebook, binding on you,
and no CLI loads it for you.** Its rules are in ROLES; humans read the role table here, machines read
`scripts/models.json` — a model swap is one edit there, never the rulebook, plus its vendor_map line.

## Who plays which role (today)

| Role | Today | Note |
|---|---|---|
| owner | the human | approves specs, merges `main` |
| orchestrator | Claude Code or Codex CLI — whichever you launch; its model comes from that CLI, not `models.json` | dispatches, reviews worker diffs, reports |
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

- Model split (`scripts/models.json`): worker BUILD `gpt-5.6-luna`; plans `gpt-5.6-sol`; artifact reviews `gpt-5.6-luna` — never the plan author's model, or every plan is refused.
- Invocation: `codex exec -m <model per split above> -c model_reasoning_effort=high
  --sandbox read-only --skip-git-repo-check - <prompt.txt` — prompt on stdin always (argv dies
  over 130KB). Web search: `-c tools.web_search=true`. Standard tier: never set `service_tier` (owner cost decision 2026-07-16).
- Consultations run detached (background or `systemd-run --user`) and may legitimately take hours —
  never a minute-scale timeout. Codex runs commands and reads the repo itself (its sandbox needs
  the `bwrap-userns-restrict` AppArmor profile loaded — without it every run dies at
  `bwrap: loopback: Failed RTM_NEWADDR`; proof: `tests/worker_userns.sh`). Inlining context is a
  choice now, not a requirement — the bound reviewer still gets spec + diff + evidence only, never
  a live checkout. The final answer is recoverable from the `--json` stream (last `agent_message`).
- **Orchestrator artifacts** go through `scripts/review`: it refuses the reviewer's own recorded author
  model, and the whole vendor where none is recorded — there `--author` IS that unauthenticated vendor,
  elsewhere only a cross-check (SECURITY.md gap 8). Worker diffs go to the bound reviewer in
  `scripts/models.json`; both are model-level. Five rounds each; a sixth is refused.
- Plans go through `scripts/codex-plan --brief` (cap 400; refuses a brief missing any required
  section); the no-flag standard tier remains usable. Trigger: CLAUDE.md rule 5.

## How a task is reported (CLAUDE.md rule 4)

Work quietly: no play-by-play, no pasted tool output, delegate anything past ~3 steps to a subagent
and relay its conclusion. Close the task with only this block — **Bottom line** (the outcome in one
sentence), **Changed** (files or state touched), **Verified** (what was run and what it actually
returned; never claim it for something that did not run), **Open** (risks or leftovers, omitted when
there are none). A failure gets the same block, failure as the bottom line. Answering a question is
not a task: one or two sentences, no block. Claude Code loads these same rules from
`.claude/output-styles/bluf.md` (via `.claude/settings.json`); it never reads this file, Codex only does.
