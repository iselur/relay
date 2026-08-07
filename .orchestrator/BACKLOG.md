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

Nothing. (In-flight work lives in the private ledger, not here.)

The known security gaps are recorded in SECURITY.md and are deliberately NOT queued here: the owner
knows them, accepts them, and does not want them built (2026-08-06). Do not re-add them.

## Parked (owner 2026-07-16: keep for the future)

- In-flight session-to-session handoff (deferred in the lifecycle-program descope, owner
  2026-07-16): atomic handoff commit/consumption, duplicate suppression, mid-handoff crash
  recovery. If revived, rebuild in Python; the hardened scenario matrix is preserved on the
  lifecycle-falsifier branch.
- Measure whether review catches bugs: plant three known defects, count catches, size review scope from the result.
- External benchmark score and cost reporting — after a real product exists.
- Test the rendered reviewer EVIDENCE section (incl. spec-declared commands) directly instead of
  relying partly on a source-marker grep (harness-spec-command-evidence round 1, PASS backlog note).
- Relax scripts/review's model-level self-review refusal to instance/context level to match
  CLAUDE.md rule 7 (owner, 2026-08-06) — stricter-than-rule today, safe to keep until needed.
