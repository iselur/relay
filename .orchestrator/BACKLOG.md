# BACKLOG — why we are here, and what is next

New ideas land here, never into flight. Pulling an item into work requires `scripts/intake` with a
definition of done. A real product outside this repo must always be somewhere on this list — the
one measured failure of this setup was pointing itself at itself (CI checks the list is never
without one).

## Why (the operator's own description of what this system is for)

A combination of an **AI engineering manager and AI engineers**: the orchestrator manages, judges,
reviews, and holds the trust boundary; the workers plan, research, implement, and test. The
capability the operator wants is end to end — drop an idea on it and it grills the idea, reconciles
a recommendation, breaks it into tickets, logs them, improves the plan, executes, reviews the
result, tests it, deploys it, and maintains what it ships. Every holistic review measures the setup
against this description: what matches, what doesn't, what is missing.

## Next up (operator-ordered)

1. **Finish the lean cleanup** — merge the docs, plain-language the rules, reframe the README,
   tier the brief policy. In flight.
2. **Auto-resume after a usage window** — a long-lived session plus a small watchdog that restarts
   it and alerts when work is pending but nothing has run. Approved by the operator 2026-07-14;
   replaces the one-shot timers deleted on 2026-07-13.
3. **Ship a real product, end to end** — pick the top idea from the private shortlist
   (`~/orchestrator-private/IDEAS-shortlist/`), give it its own repo, and push one deliberately
   small feature through idea → brief → tickets → build → test → review → merge → running.
   product: new repo from the private shortlist (name it at intake)
4. **Close the worker credential/network gap** (SECURITY.md gap 1): remove or broker the Codex
   login exposure and block build-phase network, or state per-spec why it must stay.
5. **Make approvals human-provable; grant covers low risk** (SECURITY.md gap 2; owner 2026-07-16):
   the autonomy grant authorizes low-risk dispatches, no per-spec file; default/high risk keep
   owner approvals on a mechanism software on this box cannot fabricate. Owner confirms `main` only.
6. **Move the test grade out of the worker's reach** (SECURITY.md gap 3): result file outside the
   worktree; protect `scripts/test` like the tests it runs.
7. **Measure whether review catches bugs**: plant three known defects, run the normal pipeline,
   count catches; set review scope based on the result, not on faith.
8. **Work the 2026-07-15 Codex audit findings** — 18 defects, 8 high, in the dispatcher's
   approval, grading, cancel, and merge gates. Report (on this box, untracked):
   `.orchestrator/reviews/codex-audit-2026-07-15/report.md`. Trust-critical; overlaps items 5–6.
9. **Program B (rev 4, after A)** — rotation, task leases, watchdog, compaction lifecycle; falsifier first.
10. **Program C (rev 4, after B)** — thin orchestrator, specialists, authoring flip, unpin `CLAUDE_CODE_SUBAGENT_MODEL`.

## Parked

- External benchmark score and cost reporting — after a real product exists.
