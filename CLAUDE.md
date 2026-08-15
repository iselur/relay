# CLAUDE.md — operating rules

This file is the whole rulebook; CI caps its size. A new rule requires a real failure in shipped
work and REPLACES a line, never stacks. Roles, not model names: **owner** (the human),
**orchestrator**, **worker**, **reviewer** — scripts/models.json maps the roles scripts consume; the orchestrator is its own CLI's setting. **Read AGENTS.md too — the commands and the exact CLI invocations live only there, and no CLI loads it for you.**

## Session start

Run `./scripts/dispatch reconcile`; resume from state files, never ask the owner to reconstruct. Prefer a fresh session per workstream.

## Working rules

1. **Intake:** one-line goal and checkable definition of done before any task; ask the owner if
   either is missing. `scripts/intake` before work, close with evidence, `scripts/intake stale` at
   session end — open rows raised to the owner, never dropped. Ledger private, not in this repo.
2. **One workstream:** one active execution stream. New ideas, and any unrequested improvement no evidenced failure or named invariant demands, go to `.orchestrator/BACKLOG.md`, never beside current work or into flight. Business ideas stay private.
3. **Review cap:** a holistic senior-engineer review — correctness, security, simplicity, maintainability — framed by `.orchestrator/REVIEW-FRAMING.md`; comprehensive
   round one, and good code passes round one; up to five rounds, each answered by one revision. A finding blocks only when material and acceptance-relevant — a real
   defect, a significant gap against the brief, or over-engineering answered with a concretely sketched simpler version — the rest go to the backlog, never a forced
   revision. If material findings persist past round two or three, or a spec fails its second worker attempt, never just stop or re-dispatch harder: step back as the
   owner would and weigh simplifying, another approach, splitting smaller, or another route to the goal; a re-scope restarts as a fresh brief and intake row, telling the owner. Trust-critical work with an unresolved material finding stays BLOCKED: escalate, never ship on a spent cap.
4. **Communication:** bottom line first, stay brief — never narrate steps or paste tool output; the
   to-do list past one step is the tool panel, never prose, and never back-filled. Close a task with
   the `## BLUF` block AGENTS.md defines. Coin a term only for code that exists in this repo.
5. **Every program gets ONE brief, capped at 400 lines** (`scripts/codex-plan` enforces the cap and
   required sections). A one-change, reversible task nothing else depends on needs only the intake
   gate; everything else is written to the brief. It says: the owner's request, verbatim; what exists at the end that does not now;
   what is deliberately not being done; the decisions you already made and what would justify
   reopening one (a technical guess is never one of those — it goes in the assumptions, with its
   evidence, and any assumption about an external tool cites a dated probe of the tool's real
   behavior); the smallest end-to-end run that would prove the whole approach wrong, done FIRST; each
   checkpoint with the command that proves it passed, who decides, and what happens when it fails;
   how the work is verified; how it is undone; what is left for later; and how anyone outside can
   tell it is done; and the slices — independently shippable increments, several small PRs over one
   big one. Reviewed once, then the program runs end to end — the owner steps in only at the
   checkpoints. Reference the brief, never copy it; what we learn later is added with a date and reopens the
   checkpoints it touches. Briefs and shipped specs are working files: delete them once the work ships, git keeps them.
6. **Cross-checking earns its cost** on ideas, briefs, and plans — a plan leaves plan mode only
   after `scripts/review --author <the plan's own author>` completes and its findings are answered under rule 3;
   deterministic checks and tests outrank model agreement elsewhere — agreement is not evidence.
7. **Maximal delegation:** the orchestrator delegates every delegable task to a worker by default; what a worker cannot take for architectural reasons (it needs the
   orchestrator's harness) goes to parallel subagents in isolated worktrees, several at once when the pieces are independent; the orchestrator works directly only on
   its own tasks (dispatch, review, the trust boundary). Nothing reviews its own context's work — separate instances, even of the same model, may review each other (owner, 2026-08-06); the owner sets worker and reviewer models and vendors in scripts/models.json.
8. **Code discipline:** the simplest, cleanest solution that works, held to a deletion test before a spec exists — name what the definition of done
   needs that installed code cannot do; nothing means no spec — and again at brief and diff review: anything the approved outcome, existing external
   contracts, and named safety invariants can be met at least as simply without is omitted — tests, symmetry, or hypothetical future consumers never
   establish need. Diffs are surgical: touch no adjacent code, comments, or formatting; match existing style; remove only what your change orphaned.
9. **Failure discipline:** on a failure, search the web with the literal error text — secrets,
   tokens, and personal data redacted first — before the first retry; read the whole error and
   log it under the same redaction; change one variable, and never queue work behind a blocked
   step. The second identical failure is the signal, the third a hard stop — a stall that
   survives one honest round of diagnosis goes to a second model. Escalate with the finding, not
   the symptom. Every understood failure becomes a checkable rule or test before work moves on; a
   rule that was followed and still failed gets fixed, never a second stacked beside it.

## Safety invariants (never violate)

- `main` changes only by the owner, or by the orchestrator merging a `ready-for-main` PR into `main` whose own `ci` check is green and whose exact diff holds a binding PASS (owner grant 2026-07-15) — one round on the union, not a fresh ladder, where every slice in it already passed. `ready-for-main` changes only through a pull request with `ci` green.
- External-CLI workers run as a separate identity; no isolation means no launch.
  `ORCH_ALLOW_UNISOLATED=1` needs the owner's explicit instruction, and its use is recorded.
  Subagent workers run inside the orchestrator's own session and trust domain.
- A test that did not run did not pass; a worker's prose is never a grade.
- Every high-risk dispatch needs an approval file whose authority is the owner's own words: the
  orchestrator transcribes them verbatim in the note and never originates one. Editing the spec
  voids it. Unclassified or ambiguous work is high-risk; nothing may classify it as lighter.
- A safety-machinery change is never checked, approved, reviewed, or merged by the new version of
  itself: the installed version runs every gate, and the new one goes live only after separate
  approval and installation.
- The reviewer gets only spec, diff, and evidence — claude: all tools denied; codex: read-only
  sandbox (accepted residual, SECURITY.md); the verdict binds, and covers only the exact code it
  was shown; moved code means a fresh review.
- Owner credentials stay inside the orchestrator trust domain; external-CLI workers cannot reach
  the owner's home. Known gaps are in SECURITY.md. Never claim more protection than tests prove.
- Sessions run `vigil check` on start and `vigil claim <id>` on taking a ledger entry; the hourly vigil watchdog (R123) alerts the owner and auto-resumes dead owning sessions — two strikes, then quarantine. A session blocked on an owner decision runs `vigil blocked <id> "<ask>" --recommend <answer> --by <time>` and, if unanswered by the deadline, proceeds with its stated recommendation — never where a rule requires the owner's own act (high-risk approval files, promotion to `main`, any human-required gate) (owner grant 2026-08-09).
- Stop a job with `dispatch cancel`, never by killing a process number — that once killed the
  wrong thing. Interrupted work restarts as a fresh attempt; never finish it by hand.
- Under an autonomy grant the orchestrator finishes the job itself instead of pausing for owner
  input: it answers findings under rule 3 and, `ci` green, merges to `ready-for-main` through the
  gated `./scripts/dispatch merge` or `dispatch integrate` — and to `main` where granted, never a bare `gh pr merge`. A spent cap or stop-early is answered by a rule-3 re-scope that PROCEEDS, telling the owner; only HALT or a human-required act stops it, and a rule is never itself the blocker (owner 2026-08-14).
  No grant file — untracked `AUTONOMY.local.json`, or the tracked `AUTONOMY.json` that ships disabled — means no autonomy.
