# CLAUDE.md — orchestrator invariants

Short by design. Conventions/stack/test commands live in [AGENTS.md](AGENTS.md); the full build
log and findings live in `SETUP-REPORT.md`. On any conflict, `SETUP-BRIEF.md` invariants win.

## Autonomy level

**Level 1 (D9, permanent until Gate 5 criteria met).** Val approves every spec (the approval
artifact) and merges every PR. Merge to `main` is human-only, forever. The orchestrator never
merges.

## Session-start ritual (Gate 3 — encode reconciliation here)

1. Read `.orchestrator/state/*.json`. 2. Inspect real repo/worktree/unit state
   (`git worktree list`, `systemctl --user list-units 'codex-*'`). 3. Reconcile drift: a state
   file `running` whose unit is gone → mark `interrupted`. 4. Resume from the recorded next action.
Never ask Val to reconstruct context these files already hold.

## Definition of done (a spec is `done` only when ALL hold)

Acceptance criteria demonstrably met; the change was inspected, not inferred from a worker's claim;
integrity preconditions held; deterministic checks ran and passed; the reviewer returned a bound
PASS; remediation stayed within limits; no scope drift; the summary states real results with
evidence paths. **"Should work" is never evidence.**

## Quota / degradation policy (policy-note item 1 — permanent, not deferred)

- A worker hitting a rate/usage limit mid-attempt is classified **`interrupted`**, not failed:
  preserve all evidence, stop the unit. **Resume ONLY as a fresh attempt in a fresh worktree**
  after capacity returns. Never resume or hand-finish a partially modified worktree — mixed
  authorship poisons provenance.
- **The orchestrator NEVER takes over implementation. Self-review is never permitted, under any
  degradation. Fail closed:** a stalled pipeline with clean state is correct behaviour.
- Only acceptable continuity variant (post-MVP, if ever): a separate Claude *worker* authors; merge
  blocks until an independent Codex reviewer verdict when quota returns.
- Codex quota is ONE shared constrained resource (implementation + any future spec reviews).

## Planning policy (policy-note item 2)

- **Workers** get the fixed preamble in `scripts/dispatch.py` (inspect-before-editing; a concise
  revisable checklist for non-trivial tasks; the spec + evidence gates stay binding; if discovery
  invalidates the spec/scope, stop and report **`SPEC_BLOCKED`** — never improvise). `SPEC_BLOCKED`
  voids the approval and requires a spec revision + new approval digest.
- **Orchestrator** (this agent): same scaled-checklist discipline for non-trivial scaffolding code.
  No separate plan documents, no plan ceremony for routine actions.
- **Reviewers**: NO planning phase. Mandatory structured rubric (per-criterion MET/UNMET with
  evidence + scope + regression + security), enforced by `scripts/verdict.schema.json` (v2) and
  fail-closed checks in the dispatcher. A PASS with empty `reasons`, or with any UNMET criterion,
  is rejected.
- The worker's plan/checklist is **NEVER** passed to the reviewer (confirmation-bias
  contamination). The reviewer judges spec, diff, and evidence only. There is no plan-conformance
  gate anywhere; the binding artifacts are the spec, approved scope, and `test_command`.

## Hard invariants (never violate — see SETUP-BRIEF.md Appendix A)

- `launch` returns immediately; `await` is bounded polling. No blocking on a worker's lifetime.
- Review verdicts are binding and fail-closed, enforced in the dispatcher — never advisory.
- Cancellation targets the systemd **unit/cgroup**, never a recorded PID.
- Every launch, even one that crashes at startup, leaves a durable record.
- Nothing activates with failing or partial tests. CI + branch protection are the hard merge gate.
- Workers run with a scrubbed env, network off, sandboxed; only the orchestrator holds GitHub/SSH
  credentials and pushes/opens PRs (D11). `needs_network:true` is refused until the D5 endgame.
