# Orchestrator

This repo lets you get maximum from your Claude and Codex subscriptions (no API key needed) and
makes two great models work together with minimum oversight.

This setup sets Claude as Orchestrator that manages a task backlog while Workers (Codex) handle the
implementation. They can work for days without you, while the final merge remains yours.

## How it works

Give Claude (orchestrator) a task and it turns the request into a checked spec, then delegates the
build to Workers (Codex). Claude and Codex inspect and challenge the results for up to three review
rounds.

Once started, the system can continue autonomously while you are away. Its watchdog restarts work
when the five-hour usage window ends or when backlog tasks are waiting. Every change must pass
tests and verification.

Passing work becomes a pull request to `ready-for-main`. Only you can merge it to `main`.

The [visual explanation](how-it-works.html) shows the whole process on one page.

| Who | Job |
|---|---|
| Human | Chooses the work and alone merges to `main` |
| Orchestrator (Claude) | Manages tasks and delegates them |
| Worker (Codex) | Builds the requested changes |
| Both agents | Review and challenge the work |

## How to make it autonomous

Autonomy by default is off (as a precaution).
To let the orchestrator (Claude) merge gated worker pull requests to `ready-for-main` without a
per-PR click, create `.orchestrator/AUTONOMY.local.json` as described in BOOTSTRAP.md step 7.
The owner (you) is always the only one who merges `main`.

## How to set it up

Get the cheapest Hetzner shared VM — about $7/month is enough.
Install Tailscale, tmux, and Claude Code on it.
Have two subscriptions and log in for orchestrator (Claude) and worker (Codex).
Have a GitHub repository you own.

Then:

1. Create the repository from this template.
2. Clone it onto the VM.
3. Open Claude Code in the clone and paste:

```text
Read BOOTSTRAP.md and set me up gate by gate, pausing at each human step.
```

BOOTSTRAP.md handles the setup in order and pauses whenever the owner (you) must act.

## Names used here

The roles are always owner (you), orchestrator (Claude), and worker (Codex).

MIT — see [LICENSE](LICENSE).
