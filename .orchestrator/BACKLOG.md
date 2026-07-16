# BACKLOG — why we are here, and what is next

New ideas land here, never into flight; work starts only via `scripts/intake` with a definition of
done. A real product outside this repo must always be on this list (CI checks it is never without one).

## Why (the operator's own description of what this system is for)

A combination of an **AI engineering manager and AI engineers**: the orchestrator manages, judges,
reviews, and holds the trust boundary; the workers plan, research, implement, and test. The
capability the operator wants is end to end — drop an idea on it and it grills the idea, reconciles
a recommendation, breaks it into tickets, logs them, improves the plan, executes, reviews the
result, tests it, deploys it, and maintains what it ships. Every holistic review measures the setup
against this description: what matches, what doesn't, what is missing.

## Next up (operator-ordered)

1. **Auto-resume after a usage window** — long-lived session plus a watchdog that restarts it and
   alerts when work is pending but nothing has run (operator-approved 2026-07-14).
2. **Ship a real product, end to end** — top idea from `~/orchestrator-private/IDEAS-shortlist/`,
   its own repo, one small feature through idea → brief → tickets → build → test → review → merge → running.
   product: new repo from the private shortlist (name it at intake)
3. **Close the worker credential/network gap** (SECURITY.md gap 1): remove or broker the Codex
   login exposure and block build-phase network, or state per-spec why it must stay.
4. **Make approvals human-provable; grant covers low risk** (SECURITY.md gap 2; owner 2026-07-16):
   grant authorizes low-risk dispatches, no per-spec file; default/high risk keep owner approvals
   on a mechanism this box's software cannot fabricate. Owner confirms `main` only.
5. **Move the test grade out of the worker's reach** (SECURITY.md gap 3): result file outside the
   worktree; protect `scripts/test` like the tests it runs.
6. **Measure whether review catches bugs**: plant three known defects, run the normal pipeline,
   count catches; set review scope based on the result, not on faith.
7. **Work the 2026-07-15 Codex audit findings** — 18 defects, 8 high, in the dispatcher's approval,
   grading, cancel, and merge gates; trust-critical, overlaps items 4–5. Report (untracked):
   `.orchestrator/reviews/codex-audit-2026-07-15/report.md`.
8. **Program B (rev 4, after A)** — rotation, task leases, watchdog, compaction lifecycle; falsifier first.
9. **Program C (rev 4, after B)** — thin orchestrator, specialists, authoring flip, unpin `CLAUDE_CODE_SUBAGENT_MODEL`.
10. **Raise the review-round cap from 3 to 5** (owner 2026-07-16, spent-cap escalation during the
    worker-adapter review): CLAUDE.md rule 3, `scripts/review`'s round counter/refusal,
    tests/review_cap.sh — review-machinery change, its own gated row, judged by installed gates.
11. **Fix failed_launch terminal statuses** — three shipped `_run_pipeline` refusal paths
    (ERR_NO_ISOLATION, two deadline refusals) record failed_launch, in neither TERMINAL nor LIVE, so
    `dispatch await` polls 8h (worker-adapter round-3 finding). Small spec: error_launch or TERMINAL, plus await test.

## Parked

- External benchmark score and cost reporting — after a real product exists.
