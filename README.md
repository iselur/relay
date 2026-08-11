# Relay

Relay lets coding agents put changes into a real repository without you reading every one.

One agent writes the code. A different agent, usually from a different vendor, reviews the exact
diff that agent produced. The tests run against exactly that code, not against a description of
it. Only then does a pull request open.

The whole design comes down to one sentence: an agent saying it worked is not evidence that it
worked.

## How a change travels

You approve a short spec — what should be true when the work is done.

A worker agent gets its own isolated copy of the repository and builds it. It never touches your
working tree, and it runs as a separate account that cannot reach your home directory or your
credentials.

The harness, not the worker, runs the tests and records what actually happened. A worker's own
account of its work counts for nothing.

A reviewer agent that did not write the code reads the exact diff and returns a verdict. That
verdict binds. If it says revise, the work goes back, up to a fixed number of rounds — then it
stops and asks you rather than grinding.

Work that passes opens a pull request against `ready-for-main`. Moving anything to `main` stays
yours.

## What this asks of you

Approve the spec at the start. Approve the promotion at the end. In between it runs unattended,
and when something is genuinely unclear it stops and says so instead of guessing.

Relay has run more than 500 production pull requests this way. The review step catches real
defects before merge often enough to be the reason the rest is safe to leave alone.

## What it does not claim

Relay is a reference implementation, not a product: Linux, GitHub, and the vendor CLIs you
already have. The isolation is real but bounded, and the boundaries are written down rather than
implied — [SECURITY.md](SECURITY.md) says what the tests actually prove, what depends on how you
deploy it, and what is still open.

## Where to look next

[How Relay works](how-it-works.html) — the same flow, drawn.

[BOOTSTRAP.md](BOOTSTRAP.md) — setup, from toolchain and GitHub access through worker isolation
to the first job.

[CLAUDE.md](CLAUDE.md) — the operating rulebook the agents follow.
[AGENTS.md](AGENTS.md) — the commands and role assignments.

Model choices live in `scripts/models.json`; the orchestrator is whichever supported CLI is
running the session.

MIT — see [LICENSE](LICENSE).
