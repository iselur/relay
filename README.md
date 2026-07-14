# Orchestrator

This repository keeps a software backlog moving through specification, implementation, review,
testing, and a human-controlled merge.

## How work moves

Give the orchestrator (Claude) a task. It turns the request into a checked spec, then delegates the
build to the worker (Codex), a sub-agent from another vendor. They inspect and challenge the result
for up to three review rounds.

Once started, a watchdog can continue the work while you are away. It restarts work when the
five-hour usage window ends or backlog tasks are waiting. Every change must pass its tests and
verification checks.

The [visual explanation](how-it-works.html) shows the whole process on one page.

## Roles

| Who | Job |
|---|---|
| owner (you) | Chooses the work, approves specs, and alone merges `ready-for-main` to `main` |
| orchestrator (Claude) | Manages the backlog, records evidence, and opens passing pull requests |
| worker (Codex) | Implements each spec in an isolated worktree and runs the required tests |

## Quick start

You need: an **Ubuntu 24.04** VPS, **Claude Code** on it, **Claude** and **Codex**
subscriptions, and a **GitHub repo** you own.

1. Use this template, clone your new repo onto the VPS.
2. Open Claude Code there and paste:

   ```
   Read BOOTSTRAP.md and set me up gate by gate, pausing at each human step.
   ```

It stops at the steps only you can do.

## License

MIT — see [LICENSE](LICENSE).
