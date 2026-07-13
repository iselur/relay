# ADOPT-fusion — should we adopt anything from Devin Fusion? (holistic, dual-vendor)

Reviewed the WHOLE Fusion architecture vs ours (not a pre-made shortlist) with an independent SOL pass
+ an independent Fable pass. They CONVERGED.

**Verdict: adopt essentially NOTHING of Fusion's core.**
- Fusion is a per-token COST architecture; we're FLAT-RATE subscription → the ~35% $ saving ≈ 0 value.
  Real "cost" for us is quota/latency/throughput, and Fusion doesn't improve those (2 concurrent agents
  may consume MORE). Its centerpiece mechanic (model-switch at compaction) is inapplicable — we don't
  control Codex's internal loop; our only knob is per-invocation `-m/-c`.
- Its centerpiece REVIEW model (lead self-reviews its own work) is Fusion's WEAKNESS and our STRENGTH.
  The "88% fully-automated merges" is a vanity/throughput stat, not a trust metric. REJECT.
- Fable's irony: we already run a MORE radical lead/sidekick split (Claude lead + Codex worker) with
  independent billing pools, independent rate limits, and UNCORRELATED model errors — properties
  Fusion's single-vendor router lacks.

**Improvements the review surfaced (to US, not from Fusion) — the real value:**
1. [SOL, lowest-risk] REGRESSION-PROOF GATE: for suitable specs, a digest-bound command that must FAIL
   on base and PASS on candidate — proves new tests actually catch the intended defect. Explicit +
   optional, never auto-inferred.
2. [SOL] Deepen the reviewer RUBRIC (we already have v2 per-criterion MET/UNMET + scope/regression/
   security) with maintainability/design + evidence citations; keep overall gate BINARY + fail-closed.
   And compute internal ASSURANCE metrics from existing provenance (straight-through rate by risk class,
   remediation/escalation rate, escaped defects/reversions, reviewer calibration, recovery-drill
   success) — NOT a published vanity autonomy %.
3. [Fable, higher-value but higher-RISK] Fix the reviewer's DIFF-ONLY BLINDNESS (its real weakness):
   it has no filesystem tools, so it can't see out-of-hunk consequences (changed fn breaking other call
   sites, deleted invariant relied on elsewhere). Give it READ-ONLY, network-off, isolated context
   scoped to the worktree at the reviewed commit. BUT this partially reverses D5's confused-deputy fix
   (we stripped Read/Grep/Glob precisely because it's Claude-as-operator on worker-controlled text), so
   it must be done via ISOLATION, and the Claude-auth location makes isolating the reviewer non-trivial.
   → CRITICAL change; dual-validate separately before building.

**Reject:** cheaper-sidekick-inside-worker (not implementable — no loop control), compaction switching
(inapplicable), self-review (anti-adoptable), vanity autonomy KPI. Optional-only: coarse spec-tier
model/effort routing (cheaper model for trivial specs, fail-closed escalation) — value is quota/latency
headroom, worth it ONLY if quota/latency becomes a real bottleneck (not now at MAX_PARALLEL=2-3).

Claude + SOL + Fable: converged. Next actions are Gate improvements, sequenced by risk.
