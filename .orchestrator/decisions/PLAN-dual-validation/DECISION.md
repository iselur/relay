# PLAN-dual-validation — codify the dual-validated planning requirement

**Question (Val, 2026-07-13):** the SOL+Claude "prepare detailed holistic plans, validated by both"
method is practiced (brief, policy-note, G1-A, G4-A, D5) but NOT written as a requirement, and the
existing worker-layer planning policy ("no ceremony / plans never cross-reviewed") could be misread
as contradicting it. Val: codify it in CLAUDE.md; trigger = "everything non-trivial"; verify the
formulation with SOL first.

**SOL consulted** (detached, high reasoning): prompt + full response + events in this dir; sha256 in
sha256.txt. SOL verdict: "everything non-trivial" is unwise if left undefined, defensible if scoped
via a mechanical test to non-trivial CONTROL-PLANE decisions / durable recommendations, exempting
routine execution already gated by spec-approval + reviewer + CI. Two tiers (Standard: one
adversarial SOL pass; Critical: joint iteration). Quota discipline; no silent degrade to Claude-only.

**Claude disposition:** agree in full. SOL's mechanical 5-point test + explicit exemptions + two
tiers reconciles Val's broad intent with the fast-dev goal and the shared Codex budget, and cleanly
layer-separates from (and preserves) the worker-pipeline "no plan-conformance gate" rule.

**Scope resolved with Val (2026-07-13):** Val asked where two categories fall. Answer, consistent
with SOL's mechanical test: (1) new **business-idea/research** deliverables → the *recommendation* is
non-trivial/dual-validated; the read-only investigation feeding it is exempt. (2) **high-level
specs/requirements for new features or non-trivial bug fixes** → non-trivial/dual-validated at the
requirements/design level; the routine low-level implementation specs derived from them → exempt
(gated by approval + reviewer + CI). Both categories land on the dual-validated side; only routine
implementation-of-already-decided-intent is exempt. These are written into the CLAUDE.md invariant as
worked examples. Val's "everything non-trivial" is preserved in usable form; the broader reading
(a SOL plan per worker spec) was advised against by SOL and Claude and is NOT adopted.

**Verdicts:** Claude PASS; SOL PASS. Tier: Critical (changes a governing invariant). **Encoded in
CLAUDE.md "Dual-validated planning" (2026-07-13).**
