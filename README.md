# orchestrator — AI engineering manager using two vendors (claude and codex) to get you best results

**You bring the idea. One AI manages the work; another builds it.** You approve a small spec, a
sandboxed worker implements it, hard checks and a reviewer from the other vendor judge the result,
and a pull request lands for you. `main` is yours alone — always.

**New here?** Open **[how-it-works.html](how-it-works.html)** in a browser — one page, one diagram,
the whole system.

## The short version

1. You drop an idea: one line, plus how you'll know it's done.
2. The manager (Claude) grills it and writes a small spec. Risky work waits for your written
   approval, tied to that exact spec — edit the spec and the approval is void.
3. The worker (Codex) builds it in a sandbox: its own user, no access to your home or credentials,
   no network during tests. No sandbox means no launch.
4. Hard checks run before anyone opines: changes in scope, tests actually ran — a skipped test is
   a failure, and the worker's word counts for nothing.
5. A reviewer from the other vendor judges the exact diff, with no tools. Three rounds maximum,
   then ship or escalate.
6. A pull request lands on `integration` only with CI green. You merge to `main` by hand.

## Why two vendors

Models from the same vendor fail the same way, so the reviewer is never the author's vendor and
nothing reviews its own work. Where a test can decide, the test outranks model agreement — two
models agreeing is not evidence.

## Honest limits

The sandbox protects *your* credentials; it is not perfect. The worker holds its own login and has
network while building, approval files record intent rather than prove it, and the test grade is
not yet safe against a deliberately malicious worker. `SECURITY.md` states exactly what holds (with
the test that proves it) and what does not hold yet; the fixes are queued in the backlog.

## Quick start

You need: an **Ubuntu 24.04** VPS, **Claude Code** installed on it, **Claude** and **Codex**
subscriptions, a **GitHub repo** you own, and (recommended) **Tailscale** for private SSH.

1. Click **"Use this template"** (default branch only) and clone your new repo onto the VPS.
2. In Claude Code on the box, paste:

   ```
   Read BOOTSTRAP.md and set me up gate by gate, pausing at each human step.
   ```

It stops at the steps only you can do: provisioning, branch protection, and the Claude/Codex
logins.

## What's in here

| Path | What it is |
|---|---|
| `how-it-works.html` | the one-page visual explanation |
| `scripts/dispatch.py` / `scripts/dispatch` | launch, checks, review, merge, health, reconcile |
| `scripts/intake` | task gate: no work without a goal and a checkable definition of done |
| `scripts/review` / `scripts/codex-plan` | bounded cross-vendor review (3 rounds max) / tiered plans |
| `scripts/setup-worker-user.sh` | one-time privileged host setup for worker isolation |
| `CLAUDE.md` / `AGENTS.md` / `SECURITY.md` | operating rules, role-to-model map, honest security model |
| `specs/`, `.orchestrator/` | specs and the tracked approval/attempt records |
| `tests/` | the repo suite, including isolation drills and the prose caps |

## License

MIT — see [LICENSE](LICENSE).
