# SPEC-015 — reviewer verdict v3: advisory quality dimensions (gate stays binary)

**Trigger:** trust-critical (reviewer schema/prompt/validation — decides what merges) → **high-assurance
delegated lane** (first use since REBALANCE-codex ratification). Codex authors; parent-version
validates; pre-dispatch spec challenge + adversarial SOL design review + operator per-dispatch
approval + security regression tests + staged activation (version pinning).

## Process record
1. `challenge-prompt.txt` → `challenge-response.txt`: fresh-context SOL spec critic. **FINDINGS** (13):
   full-suite test_command; metrics eligibility only for fully-valid v3; malformed-v3 ≠ historical-v2;
   per-attempt counting; regression matrix for v2 constraints; schema-version confusion both ways;
   type/boundary tests (0/6/string/null/non-integral/extra props); non-whitespace evidence;
   differential (not just acceptance) proof that scores never gate; prompt-preservation assertions;
   "trends" narrowed to distribution+average+coverage.
2. `design-prompt.txt` → `design-response.txt`: adversarial SOL design review. **BLOCK** with material
   findings: (a) presence-of-quality-block gates structurally even though values are advisory — must be
   acknowledged + deployed atomically; (b) single-invocation anchoring/halo risk (verdict and scores
   from one reviewer call) — second-pass split deferred (doubles reviewer quota), residual ACCEPTED and
   documented in code; (c) metamorphic score-invariance tests; (d) keep 1-5 integers only with
   behavioral anchors per level + non-overlapping dimension definitions; (e) no quality-derived
   merge/retry/priority anywhere, distributions not just averages; (f) independent inspection of the
   exact gate diff before merge.
3. Spec revised to incorporate ALL of 1+2. `confirm-prompt.txt` → `confirm-response.txt`: **BLOCK**, one
   residual — in-flight attempts could be validated against a newer schema after deployment (cutover
   hazard).
4. Spec adds the **version-pinning criterion**: cmd_launch snapshots verdict.schema.json into the
   attempt evidence dir; validation uses the pinned snapshot (repo fallback only for pre-pinning
   historical attempts); dedicated cutover test. `confirm2-prompt.txt` → `confirm2-response.txt`:
   see verdict below.

## Dispositions
All challenge + design findings adopted into the spec's acceptance criteria except one, which is an
accepted documented residual: single-invocation anchoring (fix would double Claude reviewer quota per
attempt; revisit if quality data shows halo correlation).

## Verdict
- SOL design review: BLOCK → conditions incorporated → confirm round 1: BLOCK (cutover residual) →
  version-pinning criterion added → confirm round 2: **VERDICT: PASS** (`confirm2-response.txt`).
- Claude (this orchestrator): PASS on the revised spec. Dual validation complete, no unresolved
  disagreement.
- Process note (operator feedback, 2026-07-13): no upfront plan.md was written before the consults —
  the spec + this record served as the plan artifact. Accepted gap; future high-assurance items get an
  explicit plan.md (drafted by Codex, authorized by Claude) BEFORE any consult.
- Operator per-dispatch approval (required, high risk): PENDING.
