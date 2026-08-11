# Relay

Relay is a harness for running coding agents against a real repository. It is built around one
assumption: an agent's account of its own work is not evidence. Everything below exists to
replace that account with something checkable.

It runs two loops.

**The outer loop is delivery.** A request becomes a one-line goal and a checkable definition of
done. Anything larger than a single reversible change gets one written brief — what exists at the
end that does not now, what is deliberately not being done, the decisions already made, the
smallest run that would prove the approach wrong, and the slices it ships in. The brief is
cross-reviewed, then the program runs end to end and you step in only at its checkpoints. Work is
dispatched as approved specs, results are reviewed, pull requests open, and passing work is
promoted.

**The inner loop is the build.** A worker agent gets an isolated checkout and implements one
spec. The harness — never the worker — runs the installed tests against the exact candidate
commit. A second agent that did not write the code reads the exact diff and returns a structured
verdict. If that verdict says revise, the work goes back, for a bounded number of rounds, each
answered by exactly one revision.

## The machinery that makes it hold

**Specs bind.** A spec is schema-validated and digest-bound, and high-risk work needs an approval
file the orchestrator is forbidden to write for itself. Editing the spec voids the approval. That
prohibition is a rule with an audit trail, not something the filesystem enforces: software running
in the owner's own context can write one, and `SECURITY.md` says so.

**Workers are isolated, and how much depends on which kind.** Every worker builds in its own git
worktree, never your working tree. A worker driven through an external CLI runs as a separate
operating-system identity, and a test asserts it cannot traverse the owner's home directory or
read the credential files there. That is narrower than "workers have no credentials", which is
not true and is not claimed: one vendor's setup stages a copy of a login inside the worker's own
home. A subagent worker is outside all of this by design — it runs inside the orchestrator's own
session and shares its trust domain. `SECURITY.md` says which guarantee applies where, and what
is still open.

**The grader restores the installed tests.** A worker cannot pass by rewriting the assertion it
failed: grading runs the tests as the repository has them, against the worker's exact commit, and
refuses to grade at all if the tree it is grading has drifted.

**The review that gates a worker's diff is structured and narrow.** It returns JSON checked
against a pinned schema, so a reviewer that emits prose and no verdict cannot pass anything, and
the verdict binds only the exact code it was shown — moved code means a fresh review. Reviews of
plans and of a promotion are prose and carry no such validation, even though the rules do gate on
them: a plan leaves plan mode only after its review is answered, and promotion to `main` requires
a binding PASS on that exact diff.

**Nothing reviews its own work.** A review always runs in a fresh instance, never the one that
produced the work. Where the author's model is on record, that fresh instance may share it — the
separation is between instances, not between models. What the tool refuses outright is the case it
cannot decide: an artefact whose provenance shows only the reviewer's own vendor with no author
model recorded. Whether reviewer and worker are different vendors at all is your configuration
choice in `scripts/models.json`, not a property of the harness.

**Failure has a budget.** Attempts against one spec are capped. A spec that fails structurally
stops rather than looping, and an escalation carries the finding rather than the symptom. Review
rounds are capped in code, because a cap written only in prose already lost once to a ten-round
loop.

**Every attempt leaves replayable evidence.** Its launch and result records and raw evidence stay
on disk; attempts that reach review also retain that binding review. What happened can be checked
afterwards rather than believed.

**Autonomy is a file, not a mood.** A grant names its scope, its gates and its risk classes, and
deleting the file revokes it. A watchdog notices a session that has died or is blocked on your
decision, and either resumes it or tells you.

**The repository caps its own prose.** Standing documentation is allowlisted and line-capped by a
test, because this repo once held roughly 39,000 lines of process prose against 4,000 lines of
code and its owner stopped understanding his own system.

## What reaches `main`

Passing work opens a pull request against `ready-for-main`, which itself only changes through a
pull request with CI green. Promotion to `main` is the owner's act, or the orchestrator's under a
recorded grant — and that grant's gates are the promotion's own green CI plus a binding review
PASS on that exact diff. No path merges to `main` on an agent's say-so.

## What it does not claim

This is a working reference implementation, not a product: Linux, GitHub, and the vendor CLIs you
already have. The isolation is real but bounded, and the boundaries are written down rather than
implied. [SECURITY.md](SECURITY.md) states what the tests actually prove, what depends on how you
deploy it, and the known gaps.

## Where to look next

[How Relay works](how-it-works.html) — the same two loops, drawn.
[BOOTSTRAP.md](BOOTSTRAP.md) — setup, from toolchain and GitHub access through worker isolation to
the first job.
[CLAUDE.md](CLAUDE.md) — the operating rulebook the agents follow, and its safety invariants.
[AGENTS.md](AGENTS.md) — the commands and the exact role assignments.

Model and role configuration lives in `scripts/models.json`; the orchestrator is whichever
supported CLI is running the session.

MIT — see [LICENSE](LICENSE).
