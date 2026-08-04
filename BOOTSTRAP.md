# BOOTSTRAP — stand up your own orchestrator

Instructions for **your orchestrator CLI** — Codex by default, Claude Code the same way — running on
a fresh Ubuntu 24.04 VPS. Follow gate by gate. Stop and hand back to the human at every **[HUMAN]**
step — those are account/infrastructure actions it can't do. Everything else it runs and verifies.

## 0. Prerequisites (the human provides)

- **[HUMAN]** An **Ubuntu 24.04** VPS (2 vCPU / 4 GB is enough to start; more for heavy real-product test suites). SSH access.
- **[HUMAN]** A non-root user with **passwordless sudo** you'll operate as (any name); `sudo -n true` must succeed or the isolation gates skip instead of failing. All paths resolve to *that* user automatically.
- **[HUMAN]** (Recommended) **Tailscale** on the box and your laptop/phone; put SSH on the tailnet only and close all public ports.
- **[HUMAN]** A **Codex** subscription; the CLI goes on at gate 4, with a device-auth login.
- **[HUMAN]** Optionally **Claude Code** and a **Claude** subscription (not an API key), to run the orchestrator on Claude instead.
- **[HUMAN]** A **GitHub repo you own** (the one you created from this template). You protect `main` and `ready-for-main` at gate 3, once `ready-for-main` exists: a ruleset requiring the `ci` check and PRs, blocking force-push and deletion, no bypass actors.

## 1. Toolchain (orchestrator)

Verify/install: `git`, `gh` (GitHub CLI), `ripgrep`, `jq`, `python3` + `venv`, Node 22+. Create the
venv at exactly `.venv` (`python3 -m venv .venv`; the scripts hardcode `.venv/bin/python`) and install
`scripts/requirements.txt`. `sudo loginctl enable-linger $USER` so worker units survive logout.
Install the `bwrap-userns-restrict` AppArmor profile now, before anything runs `codex exec`, or every
sandboxed run dies at `bwrap: loopback: Failed RTM_NEWADDR`:
`sudo apt-get install -y apparmor-profiles && sudo cp /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/ && sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict`.

## 2. GitHub auth (orchestrator, with human for the login)

- **[HUMAN]** `gh auth login` (device flow), then `gh auth refresh -s workflow` so CI can be created.
- Orchestrator: `gh auth setup-git`. This comes first: `init-operator` reads your GitHub identity
  and pushes a branch.

## 3. Make this repo yours (orchestrator → `scripts/init-operator`) and protect the branches

Run **`scripts/init-operator`**. It is safe by default: it refuses to run against the original
template remote, generates a fresh per-instance identity, sets a **repo-local** git identity, leaves
autonomy **disabled**, clears the example owner state, and ensures a `ready-for-main` branch exists.
Confirm `.github/workflows/ci.yml` exists, open a trivial PR, confirm `ci` is green. **[HUMAN]** Add
the ruleset described in gate 0 to **both** `main` and `ready-for-main`; then confirm a direct push
to each is rejected.

## 4. Codex CLI login (orchestrator, human for the login)

Install the Codex CLI — either layout works for isolated workers: the npm package
(`npm install -g --prefix ~/.local @openai/codex`, which also needs a system node at
`/usr/bin/node`) or the native binary installer. **[HUMAN]** `codex login --device-auth` on your
Codex subscription (not an API key). Then confirm `codex login status` and that a trivial
`codex exec` round-trips. (`dispatch launch` verifies a worker-launchable runtime exists and
refuses with instructions if not.)

## 5. Worker isolation — the load-bearing security step (orchestrator)

Run **`scripts/setup-worker-user.sh`** (idempotent, uses sudo). It installs distro bubblewrap + acl,
creates the dedicated `codex-worker` user + `codexwork` group, moves worktrees to `/srv/codexwork`
(outside your home), copies your Codex auth into the worker's own home, and **self-verifies that the
worker is denied every one of your credentials**. Then run `bash tests/worker_isolation.sh` and
`bash tests/worker_userns.sh` (this one proves the gate-1 AppArmor profile loaded) — every drill must
pass, and a SKIP is not a pass. If any fails, STOP; do not dispatch workers.

## 6. First job end to end (orchestrator)

Write a tiny real spec in `specs/`, **[HUMAN]** approve it — the file must be
`.orchestrator/approvals/<sha256-of-the-spec-file>.json` (any other name is ignored) and match
`APPROVAL_SCHEMA` in `scripts/dispatch.py`; the orchestrator never writes one.
Then `./scripts/dispatch launch <SPEC-ID>` and `./scripts/dispatch await <attempt-id>`. Confirm it
runs the worker in isolation, passes the gates + review, and opens a draft PR. **You** merge it.

> The repo ships no sample specs — shipped specs are working files, deleted once the work ships (git
> keeps them) — so write a fresh one; a new small helper + test is the fastest.

## 7. Optional: low-risk autonomy

Autonomy ships **disabled**. To merge in-scope PRs to `ready-for-main` without a per-PR click, copy
`.orchestrator/AUTONOMY.json` to `.orchestrator/AUTONOMY.local.json` (gitignored) and set `enabled`
true with your own `ratified_by`/`ratified_at`. The grant covers every spec matching its risk and
network class, not one plan. Autonomy never reaches `main`; that promotion is a separate grant.

## Notes

- Codex consultation conventions (detached runs, never a minute-scale timeout): see `AGENTS.md`.
- `.orchestrator/HALT` is the kill switch: `touch` it to block all launches.
- The full operating rules are in `CLAUDE.md`; conventions in `AGENTS.md`.
