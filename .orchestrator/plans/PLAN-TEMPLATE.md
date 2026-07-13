---
id: PLAN-NNN
created: <UTC>
author: <model that drafted it>
status: draft | challenged | authorized | superseded
ledger_ref: R.. (REQUEST-LEDGER.md row)
lane: ordinary | high-assurance | control-plane
supersedes: <prior plan id, if any>
---

# PLAN-NNN — <one-line title>

> **Brief-caliber standard (operator, 2026-07-13):** every plan artifact must reach the depth of the
> original SETUP-BRIEF — a standalone document detailed enough that an agent can execute it
> autonomously with NO further clarification. Not a bullet sketch. If a section is genuinely N/A, write
> "N/A because …". Codex drafts to this template; Claude challenges + authorizes; both then follow it.

## 1. Decision & non-goals
The single decision this plan commits to, in one paragraph. Explicit non-goals / out-of-scope so the
executor cannot drift.

## 2. Current-state evidence (facts, with citations)
What is true NOW, each claim cited to a path:line / commit / attempt / evidence file. Distinguish
observed fact from assumption. This is the ground truth the design rests on — get it right or the plan
is built on sand (cf. the audit's self-referential-claims finding).

## 3. Requirements & acceptance criteria (numbered, testable)
Each requirement as a falsifiable statement. These become the spec's `acceptance_criteria` verbatim, so
write them as tests, not aspirations. Include the negative/abuse cases, not just the happy path.

## 4. Design / approach (the detailed part)
The actual mechanism: data structures, control flow, file-level changes, interfaces, invariants
preserved. Enough that implementation is transcription, not invention. Include a concrete alternatives
subsection: ≥2 alternatives considered and why THIS one wins (or why none — with reason).

## 5. Affected boundaries & consumers
Every trust boundary, shared contract, schema, credential, gate, or downstream consumer this touches.
For control/high-assurance work: the transitive dependency closure (what silently depends on this).

## 6. Ordered implementation steps
Numbered, each naming the file(s) and the concrete change, in an order that keeps the tree working.
A reviewer should be able to check the diff against these one-to-one.

## 7. Failure modes & blast radius
For each realistic failure: trigger → consequence → mitigation. What is the worst case if this ships
wrong? What is irreversible? Include the "we got it wrong" recovery path.

## 8. Validation plan (falsifiable)
The exact acceptance test(s) that prove done — including the test that FAILS on the current (broken)
state and PASSES after (the regression-proof discipline). How each acceptance criterion is
mechanically verified. "Should work" is never validation.

## 9. Rollback / irreversibility
How to undo. If irreversible, say so loudly and what containment exists.

## 10. Open questions / operator decisions
Anything only the operator can decide. If none, "none".

## 11. Provenance (filled during challenge/authorization — NOT by the drafter)
- **Challenge (Claude):** ≥1 named objection (unsupported assumption / missing failure mode / scope
  ambiguity / insufficient validation) or why none applies. "Looks good" is not a challenge.
- **Disposition (drafter):** revise / reject-with-evidence / accept-and-amend, per objection.
- **Dual-validation (high-assurance/control-plane):** SOL design-review verdict (PASS/BLOCK + rounds);
  Claude verdict. Unresolved disagreement → operator.
- **Authorization:** digest of the authorized revision; who authorized; date. Silent post-auth edits
  void it.
- **Completion reconciliation:** followed / authorized-deviation / unauthorized-deviation, at the end.
