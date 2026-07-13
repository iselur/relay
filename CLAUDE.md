# CLAUDE.md — orchestrator invariants

Short by design. Conventions/stack/test commands live in [AGENTS.md](AGENTS.md); the full build
log and findings live in `SETUP-REPORT.md`. On any conflict, `SETUP-BRIEF.md` invariants win.

## Autonomy level

**Level 1.5 — plan-scoped autonomy (Val ratified 2026-07-13, THIS repo only).** Val agrees a plan
scope with the orchestrator, then the orchestrator may **merge in-scope PRs to `integration`
autonomously** — no per-PR human click — via `./scripts/dispatch merge <attempt-id>`, which is
fail-closed and enforces every gate: attempt `passed_pr_opened`; bound reviewer PASS; `ci` green;
PR head == the reviewed `worker_commit`; and the **merge-time base-check** (base still == bound
`base_sha`, closing the post-PR stale-base hole). The grant lives in `.orchestrator/AUTONOMY.json`
(`enabled`, `allowed_risk_class`, `needs_network_allowed`); delete it or set `enabled:false` to
revert to Level 1. **`main` promotion stays human-only, permanently** — never auto-merged.
Spec approval still binds each attempt to intent; Val reviews results after the fact; `HALT` pauses
everything. This grant is per-project and does NOT transfer to the eventual real-product repo, which
gets its own explicit policy decision. Rationale + adversarial validation: `SETUP-REPORT.md` G4-A.

## Session-start ritual (Gate 3)

Run **`./scripts/dispatch reconcile`** first thing. It reads `.orchestrator/state/*.json`, inspects
real unit state (`systemctl --user`), and flips any attempt whose state is `running` but whose unit
is gone (orchestrator/box restart) to `interrupted` — resumable ONLY as a fresh attempt (never
hand-finish a partial worktree; see quota/degradation policy). Then resume from the recorded next
action. Never ask Val to reconstruct context these files already hold.

## Health monitoring (Gate 3 — soft-alert, confirm-then-cancel)

`./scripts/dispatch health <attempt-id>` (threshold `--minutes`, default 10). A stale JSONL event
stream raises an **alert, not a kill**. Silence ≠ death: a long compile/test is silent but busy.
Cancel ONLY a **confirmed hang** — unit alive but no CPU progress, no new events, and no journal
activity across **two consecutive** checks. A busy-but-silent worker (CPU advancing) always
survives.

## Definition of done (a spec is `done` only when ALL hold)

Acceptance criteria demonstrably met; the change was inspected, not inferred from a worker's claim;
integrity preconditions held; deterministic checks ran and passed; the reviewer returned a bound
PASS; remediation stayed within limits; no scope drift; the summary states real results with
evidence paths. **"Should work" is never evidence.**

## Remediation + integration (Gate 4)

- **Remediation limits by risk_class: low 5 / default 3 / high 1.** Attempt 1 is never a
  remediation; interrupted/stale_base/spec_blocked launches don't consume budget — only merit
  failures (test/review/scope/integrity) do. Each remediation is a NEW attempt whose prompt embeds
  the SPECIFIC findings of the last failure. Two consecutive identical findings = stop-early. Limit
  exhausted or stop-early → spec `failed_remediation_exhausted` + a tracked escalation record in
  `.orchestrator/escalations/` — never an infinite loop, never silent success.
- **High-risk specs need Val's per-dispatch approval artifact** (`approvals/<digest>.attempt-<n>.json`)
  before EVERY dispatch, at every autonomy level.
- **`./scripts/integrate <attempt-id>…`** is the deterministic integration step: merges in
  `depends_on` order via the base-checked `dispatch merge`, re-runs the suite after every merge,
  cleans up worktree/branch, auto-commits provenance (spec + approvals + attempt evidence +
  escalations). Merge conflict or suite failure = stop/escalate — never AI-resolved.

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
- **Parallelism (Gate 3 part 3): `MAX_PARALLEL=2`.** The slot claim is atomic (`claim_slot`, under
  the STATE lock): at most 2 live attempts, at most one live attempt per spec. Each attempt has a
  unique branch/worktree. **Stale base is refused, never hand-rebased:** if the base branch advanced
  while an attempt ran (a sibling integrated), the dispatcher records `stale_base` at push and opens
  no PR; the orchestrator re-launches a **fresh** attempt off the new base so ALL gates re-run
  against what would actually land. A reviewed verdict is only valid for the base it was bound to.
