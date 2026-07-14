# CLAUDE.md — orchestrator invariants

This file is short ON PURPOSE. Its 319-line predecessor was itself a root cause of the July
degradation (R29): rules accreted faster than product shipped. A new rule requires a failure that a
real shipment actually hit (R26), and must REPLACE something, not stack. CI enforces the size cap
(tests/rulebook_cap.sh). Conventions/stack/test commands: AGENTS.md. Retired policy text lives in
git history and .orchestrator/decisions/ — the binding parts are absorbed below.

## Working rules (R29, operator-approved 2026-07-14)

1. **Intake:** no task starts without a one-line goal and a checkable definition of done. If either
   is missing, ASK the operator — refusing to start is correct behavior. Log every task with its
   done-criterion via `scripts/intake` (ledger is private, untracked) BEFORE work, and close it
   with evidence (`scripts/intake close`) when done. Run `scripts/intake stale` at session end:
   a row that never reaches done is a process failure to surface, never to swallow.
2. **One workstream:** one active execution stream at a time. New ideas go to the backlog
   (`.orchestrator/BACKLOG.md`), never into flight alongside current work.
3. **Review cap:** draft → one adversarial review → one revision → ship or escalate to the
   operator. Never a round three. The cap bounds effort on ordinary reversible work; a
   trust-critical change with an unresolved critical finding stays BLOCKED — escalate, never
   ship on cap exhaustion.
4. **Communication:** max 5 bullets per update — Outcome / Verified / Not done / Risk / Next.
   Plain language. No coined terms unless they name code that exists.
5. **Big programs get ONE brief** (goal, staged gates, deterministic acceptance criteria),
   adversarially reviewed once, then run end-to-end; operator arbitrates only at gates. Planning
   depth scales with risk and reversibility, never with "substance."

## Safety invariants (never violate)

- `main` is human-only, permanently. `integration` changes only via PR with `ci` green.
- Workers run isolated (D5: `codex-worker` UID, operator home inaccessible, network off in test).
  Isolation FAILS CLOSED: no isolation → no launch, checked before any state is created.
  `ORCH_ALLOW_UNISOLATED=1` is recorded exposure, typed knowingly by the operator only.
- A test that did not RUN did not PASS (T1). Required tests are restored from the orchestrator's
  own checkout before grading (T1b). An empty required set fails. Worker prose is never a verdict.
- High-risk specs need the operator's per-dispatch approval artifact. Claude never mints it.
- Risk classification fails closed: unclassified or ambiguous work is high-risk. No delegation
  quota or metric may reward downgrading it.
- Bootstrap: a trust-boundary change is never validated, approved, reviewed, or merged by its own
  candidate code — the installed parent version runs every gate (T1b is the test-restore case of
  this); a candidate activates only after separate approval and install.
- Reviews are cross-vendor and fail-closed: never Codex-grades-Codex, never self-review, under any
  degradation. The reviewer sees only spec + diff + evidence (all tools denied). Verdicts bind.
- Only the orchestrator holds credentials. Workers get a scrubbed env and no network
  (`needs_network:true` is refused until the credential residual is closed).
- Stale base is refused, never hand-rebased: a verdict is only valid for the base it was bound to.
- Cancellation targets the systemd unit/cgroup, never a recorded PID.
- Every launch leaves a durable record. Nothing activates on failing, partial, or skipped tests.
- Never resume or hand-finish a partial worktree — interrupted work restarts as a fresh attempt.
- Autonomy: OFF by default; Level 1.5 only via untracked `AUTONOMY.local.json`;
  `./scripts/dispatch merge` enforces every gate. This never extends to `main`.

## Session start

Run `./scripts/dispatch reconcile` first. Resume from recorded state — never ask the operator to
reconstruct what the state files already hold. Prefer a fresh session per workstream over marathon
sessions that force context compaction (R29).

## Codex on this box

`codex exec -m gpt-5.6-sol -c model_reasoning_effort=high -c service_tier=priority
--sandbox read-only --skip-git-repo-check - <prompt.txt` — stdin always (argv dies >130KB);
web search is `-c tools.web_search=true`. Consults run detached; allow hours, never minute-scale
timeouts. The bwrap sandbox cannot read the repo on this host — inline the context.
