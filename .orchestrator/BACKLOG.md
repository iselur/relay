# BACKLOG — why we are here, and what is next

New ideas land here, never into flight; work starts only via `scripts/intake` with a definition of
done. Product work is tracked privately (owner 2026-07-17); this list carries only the harness itself.

## Why (the operator's own description of what this system is for)

A combination of an **AI engineering manager and AI engineers**: the orchestrator manages, judges,
reviews, and holds the trust boundary; the workers plan, research, implement, and test. The
capability the operator wants is end to end — drop an idea on it and it grills the idea, reconciles
a recommendation, breaks it into tickets, logs them, improves the plan, executes, reviews the
result, tests it, deploys it, and maintains what it ships. Every holistic review measures the setup
against this description: what matches, what doesn't, what is missing.

## Next up

1. **Restrict worker build-phase egress before the first product-repo dispatch** (SECURITY.md gap 1,
   LOW-MEDIUM 2026-07-16): worker uid reaches only the model API; the credential-broker fix stays parked.

## Parked (owner 2026-07-16: keep for the future)

- In-flight session-to-session handoff (deferred in the lifecycle-program descope, owner
  2026-07-16): atomic handoff commit/consumption, duplicate suppression, mid-handoff crash
  recovery. If revived, rebuild in Python; the hardened scenario matrix is preserved on the
  lifecycle-falsifier branch.
- Approvals rework (SECURITY.md gap 2): the autonomy grant covers low risk, owner confirms `main` only.
- Move the test grade fully outside candidate/operator influence (SECURITY.md gap 3 residuals): the
  grader tree is now materialized from the pinned git tree and run from a fresh checkout, closing
  worker replacement of the runner or tests; malicious candidate code the test executes can still
  forge a misleading success, and a same-uid operator could race that temp checkout.
- Measure whether review catches bugs: plant three known defects, count catches, size review scope from the result.
- 2026-07-15 audit remainder: re-verified 2026-07-16 — seven of eight highs already fixed on main,
  the last a low-risk merge-window race (owner enables GitHub's up-to-date-branch rule); four
  state-machine mediums confirmed but low risk. Report: claude-out/audit-reverify-2026-07-16.md.
- `scripts/review` provenance, three holes: a file under a worker worktree is `codex` by path alone (a
  Claude or Kimi reviewer then fails OPEN — read `launch.json` `worker_model` instead); an `author_model:`
  stamp is the author's own word, so an author can understate itself (needs a digest-bound receipt written
  at dispatch by something other than the author); and it compares config model ids, so re-pointing a
  `cli_aliases` target after authoring lets a differently-named reviewer invoke the same provider model
  (R102 round-3 — needs the invoked identity stamped at authoring time).
- External benchmark score and cost reporting — after a real product exists.
- Test the rendered reviewer EVIDENCE section (incl. spec-declared commands) directly instead of
  relying partly on a source-marker grep (harness-spec-command-evidence round 1, PASS backlog note).
- Relax scripts/review's model-level self-review refusal to instance/context level to match
  CLAUDE.md rule 7 (owner, 2026-08-06) — stricter-than-rule today, safe to keep until needed.
