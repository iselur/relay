# CLAUDE.md — operating rules

This file is the whole rulebook; CI caps its size. A new rule requires a real failure in shipped
work and REPLACES a line, never stacks. Roles, not model names: **owner** (the human),
**orchestrator**, **worker**, **reviewer** — scripts/models.json maps roles to today's models; AGENTS.md holds the commands.

## Session start

Run `./scripts/dispatch reconcile`; resume from state files, never ask the owner to reconstruct.
Prefer a fresh session per workstream.

## Working rules

1. **Intake:** one-line goal and checkable definition of done before any task; ask the owner if
   either is missing. `scripts/intake` before work, close with evidence, `scripts/intake stale` at
   session end — open rows raised to the owner, never dropped. Ledger private, not in this repo.
2. **One workstream:** one active execution stream. New ideas go to `.orchestrator/BACKLOG.md`,
   never beside current work. Business ideas stay private.
3. **Review cap:** up to three adversarial review rounds, each answered by one revision.
   Trust-critical work with an unresolved critical finding stays BLOCKED: escalate, never ship on
   a spent cap.
4. **Communication:** bottom line first, stay brief. Past one step, keep a live to-do list, never
   back-filled. Coin a term only for code that exists in this repo.
5. **Every program gets ONE brief, capped at 400 lines** (`scripts/codex-plan` enforces the cap and
   required sections). A one-change, reversible task nothing else depends on needs only the intake
   gate; everything else is written to the brief. It says: what exists at the end that does not now;
   what is deliberately not being done; the decisions you already made and what would justify
   reopening one (a technical guess is never one of those — it goes in the assumptions, with its
   evidence); the smallest end-to-end run that would prove the whole approach wrong, done FIRST; each
   checkpoint with the command that proves it passed, who decides, and what happens when it fails;
   how the work is verified; how it is undone; what is left for later; and how anyone outside can
   tell it is done. Reviewed once, then the program runs end to end — the owner steps in only at the
   checkpoints. Reference the brief, never copy it; what we learn later is added with a date and
   reopens the checkpoints it touches. Briefs are working files: delete them once the work ships,
   git keeps them.
6. **Cross-checking earns its cost** on ideas and briefs; deterministic checks and tests outrank
   model agreement everywhere else — agreement is not evidence.
7. **Maximal delegation:** the orchestrator delegates every delegable task to the worker, and works
   directly only when no worker is available or the task is its own (dispatch, review, the trust
   boundary). Nothing reviews its own work; the owner sets role models and vendors in scripts/models.json.

## Safety invariants (never violate)

- `main` changes only by the owner, or by the orchestrator merging a `ready-for-main` PR into `main` whose own `ci` check is green and whose exact diff holds a binding PASS (owner grant 2026-07-15). `ready-for-main` changes only through a pull request with `ci` green.
- External-CLI workers run as a separate identity; no isolation means no launch.
  `ORCH_ALLOW_UNISOLATED=1` needs the owner's explicit instruction, and its use is recorded.
  Subagent workers run inside the orchestrator's own session and trust domain.
- A test that did not run did not pass; a worker's prose is never a grade.
- Every high-risk dispatch needs an approval file from the owner, which the orchestrator never
  writes. Editing the spec voids the approval. Unclassified or ambiguous work is high-risk;
  nothing may classify it as lighter.
- A safety-machinery change is never checked, approved, reviewed, or merged by the new version of
  itself: the installed version runs every gate, and the new one goes live only after separate
  approval and installation.
- The reviewer gets only spec, diff, and evidence — no tools; the verdict binds. A verdict covers
  only the exact code it was shown; moved code means a fresh review.
- Owner credentials stay inside the orchestrator trust domain; external-CLI workers cannot reach
  the owner's home. Known gaps are in SECURITY.md. Never claim more protection than tests prove.
- Stop a job with `dispatch cancel`, never by killing a process number — that once killed the
  wrong thing. Interrupted work restarts as a fresh attempt; never finish it by hand.
- Autonomy is off by default and needs an explicit grant file — untracked `AUTONOMY.local.json`,
  or the tracked `AUTONOMY.json` that ships disabled. Autonomy reaches only `ready-for-main`,
  through the gated `./scripts/dispatch merge` or `dispatch integrate` — never a bare
  `gh pr merge`, never `main`.
