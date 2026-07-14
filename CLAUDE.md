# CLAUDE.md — operating rules

This file is the whole rulebook and CI caps its size (tests/rulebook_cap.sh). A new rule is
admitted only for a failure that real shipped work actually hit, and it must replace an existing
line, never stack. Conventions and commands: AGENTS.md. Security model, honestly: SECURITY.md.
Past decisions, one line each: DECISIONS.md. Everything else lives in git history.

## Working rules

1. **Intake:** no task starts without a one-line goal and a checkable definition of done. If either
   is missing, ask the operator — refusing to start is correct behavior. Log every task via
   `scripts/intake` (ledger is private, untracked) BEFORE work; close it with evidence
   (`scripts/intake close`); run `scripts/intake stale` at session end and surface any row that
   never reached done.
2. **One workstream:** one active execution stream at a time. New ideas go to
   `.orchestrator/BACKLOG.md`, never into flight alongside current work. Backlog item #1 must be
   a real product outside this repo — improving this system is never item #1.
3. **Review cap:** draft → one adversarial review → one revision → one confirmation look at the
   revision → ship or escalate to the operator. Never a third review round — `scripts/review`
   counts rounds and refuses it. A trust-critical change with an unresolved critical finding stays
   BLOCKED: escalate, never ship on cap exhaustion.
4. **Communication:** max 5 bullets per update — Outcome / Verified / Not done / Risk / Next —
   plus one cost line (tokens/quota used, both vendors). Plain language: a coined term is allowed
   only if it names code that exists in this repo (CI enforces tests/plain_language.sh).
5. **Big programs get ONE brief** (goal, staged gates, checkable acceptance criteria), reviewed
   once, then run end to end; the operator arbitrates only at gates. Planning depth scales with
   risk and reversibility. Plans are untracked working files, deleted after the work ships.
6. **Cross-checking between Claude and Codex is spent where it earns its cost:** idea research,
   the brief, and trust-critical code. Everywhere else, deterministic checks and tests outrank
   model agreement — two models agreeing is not evidence.
7. **Codex does most work** (research, drafts, implementation, tests); Claude orchestrates,
   dispatches, reviews, and reports. Never Codex-grades-Codex, never self-review.

## Safety invariants (never violate)

- `main` is human-only, permanently. `integration` changes only via PR with `ci` green.
- Workers run isolated: dedicated `codex-worker` user, operator home unreachable, no network
  during tests. No isolation → no launch, checked before any state is created.
  `ORCH_ALLOW_UNISOLATED=1` is full, recorded exposure — never set it without the operator's
  explicit instruction (it records use; it cannot prove who set it — SECURITY.md gap 2).
- A test that did not RUN did not PASS. Required tests are restored from the orchestrator's own
  checkout before grading; an empty required set fails. Worker prose is never a verdict. (This
  gate stops accidental skips; the malicious-grader case is SECURITY.md gap 3, queued.)
- High-risk specs need the operator's per-dispatch approval file. Claude never creates one.
  Unclassified or ambiguous work is high-risk; no metric may reward downgrading it.
- A trust-boundary change is never validated, approved, reviewed, or merged by its own candidate
  code — the installed version runs every gate; the candidate activates only after separate
  approval and install.
- The reviewer sees only spec + diff + evidence (all tools denied) and its verdict binds. A verdict
  is valid only for the base it was bound to: a stale base is refused, never hand-rebased.
- Only the orchestrator holds the operator's credentials; workers get a scrubbed environment.
  Known gaps in this story are listed in SECURITY.md and queued in the backlog — docs never claim
  more than the tests prove.
- Cancellation targets the systemd unit, never a recorded PID. Every launch leaves a durable
  record. Nothing activates on failing, partial, or skipped tests. Interrupted work restarts as a
  fresh attempt, never hand-finished.
- Autonomy: OFF by default; granted only via untracked `AUTONOMY.local.json`; only
  `./scripts/dispatch merge` (which enforces every gate) may use it; never extends to `main`.

## Session start

Run `./scripts/dispatch reconcile` first and resume from recorded state — never ask the operator
to reconstruct what the state files already hold. Prefer a fresh session per workstream over
marathon sessions. How to run Codex on this box: AGENTS.md.
