# Relay

Relay lets you get maximum from your Claude and Codex **subscriptions** 💸 (no API key needed) and
makes two great models work together with minimum oversight, passing work between them like a relay
team.

The **Orchestrator**👩‍🏫 (today Claude) manages a task backlog while **Workers**👷 handle the
implementation — the worker and reviewer models are set in `scripts/models.json`. They can work for days without you; the final merge is yours, or the
orchestrator's under your recorded grant.

## How it works

Give the Orchestrator a task and it turns the request into a checked spec, then delegates the
build to Workers. The Orchestrator and Reviewer inspect and challenge the results for up to five
review rounds.

Once started, the system can continue autonomously while you are away: work already dispatched
runs to completion without you. Every change must pass tests and verification.

Passing work becomes a pull request to `ready-for-main`. Promotion to `main` is yours — or the
orchestrator's, only under your recorded grant (green `ci` plus a binding PASS from an
independent reviewer on the exact diff).

The [visual explanation](how-it-works.html) shows the whole process — and who does which job —
on one page.

## Why Relay is different 🛡️

Most agent frameworks coordinate AI agents and trust what the agents say. Relay is built like
CI/CD with a trust boundary: the load-bearing claims are backed by gates a machine checks, and
the ones that are not are written down as configured assumptions or known gaps.

- **Evidence, not prose.** A worker saying "tests passed" counts for nothing — the tests are
  restored from the orchestrator's own copy and rerun. A test that did not run did not pass.
- **Self-review is refused on recorded provenance.** The dispatcher refuses the author's own
  model; `scripts/review` refuses the author's own vendor, on the author vendor it derives —
  derivation has recorded gaps, listed in SECURITY.md, so this is as good as the record, not a
  guarantee. The reviewer is sandboxed and given only spec, diff, and evidence; its verdict binds
  only to the exact code it saw, and moved code means a fresh review. The owner sets the pairing
  in `scripts/models.json`.
- **Isolation or no launch.** External-CLI workers run as a separate machine user that cannot
  reach your home directory or your original credentials (they hold their own copied vendor
  login), and their test runs have no network; without that sandbox they do not launch — the
  only exception is the recorded owner-ordered `ORCH_ALLOW_UNISOLATED` override. Subagent
  workers run inside the orchestrator's own session; SECURITY.md maps both boundaries.
- **A rulebook that shrinks.** The operating rules are capped by CI at 80 lines, and the
  standing policy is that a new rule requires a real failure in shipped work and replaces a
  line, never stacks.
- **Multi-vendor by design.** Claude and Codex hold the active roles today; Kimi is wired in as
  a third vendor — giving it a role is one line in `scripts/models.json`.

Honesty is part of the design: SECURITY.md lists the known gaps and the assumptions the tests
do not cover.

## How to make it autonomous 🔄

Autonomy by default is off (as a precaution).
To let the orchestrator merge gated worker pull requests to `ready-for-main` without a
per-PR click, create `.orchestrator/AUTONOMY.local.json` as described in BOOTSTRAP.md step 7.
Merges to `main` are yours unless your recorded grant lets the orchestrator promote under its
conditions (green `ci`, binding reviewer PASS).

## How to set it up

Get the cheapest Hetzner shared VM — about $7/month is enough.
Install Tailscale, tmux, and Claude Code on it.
Have subscriptions for the orchestrator CLI and for the models in `scripts/models.json`, and log each in.
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

The roles are always owner (you), orchestrator, worker, and reviewer. Worker and reviewer models come
from `scripts/models.json`; the orchestrator is whichever CLI is running.

MIT — see [LICENSE](LICENSE).
