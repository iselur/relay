# AGENTS.md — shared project conventions

Referenced by [CLAUDE.md](CLAUDE.md). Kept minimal; expanded as real conventions emerge.

## What this repo is

An orchestrator that dispatches Codex worker jobs from schema-validated specs, gates their output
(integrity → scope → test → bound review), and opens PRs the human merges. Built gate by gate per
`SETUP-BRIEF.md`.

## Stack

- **Dispatcher:** Python 3 (`scripts/dispatch.py`), venv in `.venv/` (gitignored), deps pinned in
  `scripts/requirements.txt` (pyyaml, jsonschema). Thin bash wrapper `scripts/dispatch`.
- **Repo tests / CI:** bash. `scripts/test` runs `tests/*.sh`; CI job is named exactly `ci`
  (required status check on `main` and `integration` — do not rename or add a matrix).
- **Worker helpers so far:** `scripts/lib/*.sh` (slugify, trim, repeat) — produced by dispatched
  specs; exercise the pipeline.

## Conventions

- Specs: `specs/SPEC-NNN.yaml`, schema `specs/spec.schema.json`. Immutable once approved;
  never regex-parsed. Approval artifacts in `.orchestrator/approvals/<digest>.json`.
- Branches: worker branches `codex/SPEC-NNN-<attempt>`; PRs target `integration`; only Val
  promotes `integration` → `main`. Both protected (ruleset, not classic protection).
- Evidence: per-attempt under `.orchestrator/attempts/<id>/<n>/`. Manifests tracked; raw
  logs/events + worktrees gitignored, integrity provable via tracked sha256 hashes.

## Test command

`./scripts/test` (repo suite). Individual specs declare their own `test_command`.
