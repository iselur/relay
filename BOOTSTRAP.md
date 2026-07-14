# BOOTSTRAP — stand up your own orchestrator

Instructions for **your Claude Code**, running on a fresh Ubuntu 24.04 VPS. Follow gate by gate.
Stop and hand back to the human at every **[HUMAN]** step — those are account/infrastructure actions
Claude can't do. Everything else Claude runs and verifies.

## 0. Prerequisites (the human provides)

- **[HUMAN]** An **Ubuntu 24.04** VPS (2 vCPU / 4 GB is enough to start; more for heavy real-product test suites). SSH access.
- **[HUMAN]** A non-root sudo user you'll operate as (any name). All paths in this system resolve to *that* user automatically — nothing is hardcoded.
- **[HUMAN]** (Recommended) **Tailscale** on the box and your laptop/phone; put SSH on the tailnet only and close all public ports.
- **[HUMAN]** **Claude Code** installed on the box and logged into your **Claude** subscription (not an API key).
- **[HUMAN]** A **Codex** subscription; you'll do the device-auth login when prompted.
- **[HUMAN]** A **GitHub repo you own** (the one you created from this template). Protect `main` and `ready-for-main` with a ruleset: require the `ci` check, require PRs, block force-push and deletion, no bypass actors.

## 1. Toolchain (Claude)

Verify/install: `git`, `gh` (GitHub CLI), `ripgrep`, `jq`, `python3` + `venv`, Node 22+. Create the
Python venv and install `scripts/requirements.txt`. Enable systemd linger for your user
(`loginctl enable-linger $USER`) so worker units survive logout.

## 2. Make this repo yours (Claude → `scripts/init-operator`)

Run **`scripts/init-operator`**. It is safe by default: it refuses to run against the original
template remote, generates a fresh per-instance identity, sets a **repo-local** git identity, leaves
autonomy **disabled**, clears the example owner state, and ensures an `ready-for-main` branch exists.
Review its output.

## 3. GitHub auth + CI (Claude, with human for the login)

- **[HUMAN]** `gh auth login` (device flow), then `gh auth refresh -s workflow` so CI can be created.
- Claude: `gh auth setup-git`, confirm the `ci` workflow exists (`.github/workflows/ci.yml`), open a
  trivial PR and confirm the `ci` check reports green and that a direct push to `main` is rejected by
  your ruleset.

## 4. Codex CLI (Claude, human for the login)

Install the Codex CLI. **[HUMAN]** `codex login --device-auth` on your Codex subscription (not an API
key). Claude: confirm `codex login status`, then a trivial `codex exec` round-trips.

## 5. Worker isolation — the load-bearing security step (Claude)

Run **`scripts/setup-worker-user.sh`** (idempotent, uses sudo). It installs distro bubblewrap + acl,
creates the dedicated `codex-worker` user + `codexwork` group, moves worktrees to `/srv/codexwork`
(outside your home), copies your Codex auth into the worker's own home, and **self-verifies that the
worker is denied every one of your credentials**. Then run `bash tests/worker_isolation.sh` — all
drills must pass. If any fails, STOP; do not dispatch workers.

## 6. First job end to end (Claude)

Write a tiny real spec in `specs/`, **[HUMAN]** approve it (record an approval artifact bound to this
instance), then `./scripts/dispatch launch <SPEC-ID>` and `./scripts/dispatch await <attempt-id>`.
Confirm it runs the worker in isolation, passes the gates + review, and opens a draft PR. **You**
merge it.

## 7. Optional: plan-scoped autonomy

Autonomy ships **disabled**. If (and only if) you want the orchestrator to merge in-scope PRs to
`ready-for-main` without a per-PR click, create `.orchestrator/AUTONOMY.local.json` (gitignored) with
your ratified grant. `main` stays human-only regardless. Read the autonomy line in `CLAUDE.md`'s
safety invariants first.

## Notes

- **Never** put a minute-scale timeout on a Codex consultation — run it detached; it can take a while.
- `.orchestrator/HALT` is the kill switch: `touch` it to block all launches.
- The full operating rules are in `CLAUDE.md`; conventions in `AGENTS.md`.
