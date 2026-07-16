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

## Next up (operator-ordered 2026-07-16)

1. **Auto-resume after a usage window** — long-lived session plus a watchdog that restarts it and
   alerts when work is pending but nothing has run (operator-approved 2026-07-14). Needs a plan,
   then finish: fold in the user-presence standby rework now under owner-granted extra review rounds.
2. **Program B (rev 4)** — rotation, task leases, watchdog, compaction lifecycle; falsifier first.
3. **Program C (rev 4, after B)** — thin orchestrator, specialists, authoring flip, unpin `CLAUDE_CODE_SUBAGENT_MODEL`.
4. **Ship a real product, end to end** — top idea from `~/orchestrator-private/IDEAS-shortlist/`,
   its own repo, one small feature through idea → brief → tickets → build → test → review → merge → running.
   product: new repo from the private shortlist (name it at intake)
5. **Raise the review-round cap from 3 to 5** (owner 2026-07-16, spent-cap escalation during the
   worker-adapter review): CLAUDE.md rule 3, `scripts/review`'s round counter/refusal,
   tests/review_cap.sh — review-machinery change, its own gated row, judged by installed gates.
6. **Fix failed_launch terminal statuses** — three shipped `_run_pipeline` refusal paths
   (ERR_NO_ISOLATION, two deadline refusals) record failed_launch, in neither TERMINAL nor LIVE, so
   `dispatch await` polls 8h (worker-adapter round-3 finding). Small spec: error_launch or TERMINAL, plus await test.
7. **Restrict worker build-phase egress before the first product-repo dispatch** (SECURITY.md gap 1,
   assessed LOW-MEDIUM on 2026-07-16): worker uid may reach only the model API; the full
   credential-broker fix stays parked. Assessment: claude-out/audit-reverify-2026-07-16.md.

## Parked (owner 2026-07-16: keep for the future)

- Approvals rework (SECURITY.md gap 2): the autonomy grant covers low risk, owner confirms `main` only.
- Move the test grade out of the worker's reach (SECURITY.md gap 3).
- Measure whether review catches bugs: plant three known defects, count catches, size review scope from the result.
- 2026-07-15 audit remainder: re-verified 2026-07-16 — seven of eight highs already fixed on main,
  the last a low-risk merge-window race (owner enables GitHub's up-to-date-branch rule); four
  state-machine mediums confirmed but low risk. Report: claude-out/audit-reverify-2026-07-16.md.
- Fable retirement follow-through: after the owner's manual flip, point the bound reviewer in
  `scripts/models.json` at its successor via a reviewed PR.
- External benchmark score and cost reporting — after a real product exists.
