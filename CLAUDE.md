# CLAUDE.md — operating rules

This file is the whole rulebook; CI caps its size. A new rule is admitted only for a failure real
shipped work hit, and it REPLACES a line, never stacks. Roles here, never model names: **owner**
(the human), **orchestrator**, **worker**, **reviewer** — AGENTS.md maps roles to today's models and
holds the commands; SECURITY.md says what the protections do and do not prove.

## Working rules

1. **Intake:** no task starts without a one-line goal and a checkable definition of done; ask the
   owner if either is missing. Log it with `scripts/intake` before work, close it with evidence, and
   run `scripts/intake stale` at session end — anything that never reached done is raised with the
   owner, never quietly dropped. The request ledger stays private, never in this repo.
2. **One workstream:** one active execution stream. New ideas go to `.orchestrator/BACKLOG.md`, never
   in beside current work. Business ideas stay private. A real product outside this repo is always
   somewhere on that backlog — self-improvement may be scheduled first, but never be the only thing.
3. **Review cap:** draft, then up to three adversarial review rounds, each answered by one
   revision; ship when clean. Never a fourth round — `scripts/review` refuses it. Trust-critical
   work with an unresolved critical finding stays BLOCKED: escalate, never ship on a spent cap.
4. **Communication:** lead with the bottom line, then at most five plain bullets — Outcome /
   Verified / Not done / Risk / Next; keep a visible to-do list for multi-step work. Coin a term only for code that exists in this repo.
5. **Every program gets ONE brief.** Pick the tier; when it could be two, take the higher one.
   - *Small* — one change, in one place, easy to undo, nothing else depends on it: the intake gate
     is enough. Any plan stays under 40 lines.
   - *Standard* — a bigger job that is still one job: a plan settling what is in and out, the steps,
     how it is checked, how it is undone. 100–150 lines, hard cap 250.
   - *Full brief* — several jobs sharing one goal; work you must approve part-way through; anything
     touching safety, credentials, money, live systems, or data that cannot be undone; or a design
     decision that changes several parts at once. About 250 lines, hard cap 400. It says: what
     exists at the end that does not now; what is deliberately not being done; the decisions you
     already made and what would justify reopening one (a technical guess is never one of those — it
     goes in the assumptions, with its evidence); the smallest end-to-end run that would prove the
     whole approach wrong, done FIRST; each checkpoint with the command that proves it passed, who
     decides, and what happens when it fails; how the work is verified; how it is undone; what is
     left for later; and how anyone outside can tell it is done.
   Reviewed once, then the program runs end to end — the owner steps in only at the checkpoints. One
   brief per program: reference it, never copy it; what we learn later is added to it with a date and
   reopens the checkpoints it touches. Plans and briefs are working files: delete them once the work
   ships, git keeps them. `scripts/codex-plan` enforces the caps and sections. This tiering is a
   hypothesis built on one success (the 235-line founding brief) — revisit after three programs.
6. **Cross-checking earns its cost** on ideas, briefs, and trust-critical code. Everywhere else,
   deterministic checks and tests outrank agreement between models — agreement is not evidence.
7. **Maximal delegation:** the orchestrator delegates every delegable task to the worker, and works
   directly only when no worker is available or the task is its own (dispatch, review, the trust
   boundary). The reviewer is never the same vendor as the author, and nothing reviews its own work.

## Safety invariants (never violate)

- Only the owner changes `main`. `ready-for-main` changes only through a pull request with `ci` green.
- Workers run as a separate identity that cannot reach the owner's home, and their tests have no
  network. No isolation means no launch: nothing is created, nothing runs. `ORCH_ALLOW_UNISOLATED=1`
  is full exposure, needs the owner's explicit instruction, and its use is recorded — though the
  record cannot prove who set it.
- A test that did not run did not pass. Required tests are restored from the orchestrator's own copy
  before grading; a skipped, missing, or empty result fails. A worker's prose is never a grade.
- Every high-risk dispatch needs an approval file from the owner, which the orchestrator never
  writes. An approval is tied to the exact wording of that spec and to this machine: edit the spec
  and it is void, copy it from elsewhere and it authorizes nothing. Unclassified or ambiguous work
  is high-risk, and nothing may reward calling it anything lighter.
- A change to the safety machinery is never checked, approved, reviewed, or merged by the new
  version of itself: the installed version runs every gate, and the new one goes live only after
  separate approval and installation.
- The reviewer sees only the spec, the diff, and the evidence — no tools — and its verdict binds. A
  verdict holds only for the exact code it was shown: if the code has moved on, the review is run
  again, never stretched to cover code nobody reviewed.
- Only the orchestrator holds the owner's credentials; workers get a cleaned environment. Known
  holes in that story are listed in SECURITY.md and queued in the backlog. Never claim more
  protection than the tests prove.
- Stop a job with `dispatch cancel` (it stops the job's own unit), never by killing a process number
  we wrote down earlier — that once killed the wrong thing. Every launch leaves a durable record,
  even one that dies on startup. Nothing goes live on failing, partial, or skipped tests, and
  interrupted work restarts as a fresh attempt; it is never finished by hand.
- Autonomy is off unless an untracked `AUTONOMY.local.json` grants it, only gated
  `./scripts/dispatch merge` may use it, and it never reaches `main`. It is granted in this working
  repo; the template ships with it disabled.

## Session start

Run `./scripts/dispatch reconcile` first and resume from the recorded state — never ask the owner to
reconstruct what the state files hold. Prefer a fresh session per workstream.
