---
id: PLAN-001
created: 2026-07-13T21:20:00Z
author: gpt-5.6-sol (Codex-drafted; Claude challenged + authorized)
status: authorized-with-amendments
task: Reinforce two operator rules — aggressive delegation to Codex + mandatory Codex-drafted planning
---

# PLAN-001 — make delegation + planning-first mechanically binding

**Source plan:** Codex-drafted, `.orchestrator/decisions/REINFORCE-delegation-planning/plan-response.txt`
(this file is the authorization record; the source draft is authoritative for anything not amended here).
This is also the FIRST artifact of the workflow it defines: Codex drafted it; Claude challenged and
authorized it.

## Claude's challenge (mandatory — "looks good" is not a valid challenge)
1. **Contradiction with ratified invariant:** the week-2 numeric acceptance targets (≥90% delegable
   work to Codex etc.) recreate the delegation-ratio-as-target Goodhart hazard that REBALANCE-codex
   invariant 4 explicitly forbids — pressure to classify borderline work downward.
2. **Unsupported assumption:** the 15/70/15 quota scheduler classes assume a local metering signal for
   Codex quota that does not exist (no API for remaining weekly quota on this plan).
3. **Missing failure mode:** the `dispatch.py` plan_ref hard gate has a bootstrap problem (SPEC-001..015
   have no plans) and is itself a trust-critical dispatch change; the CI text-matching check
   ("references a decision record") is gameable by content and brittle.
4. **Scope ambiguity / ceremony bloat:** the planless fast path is so narrow (greetings, lookups) that a
   conversational question ("explain diff blindness") would require a Codex plan consult first —
   latency + quota ceremony with no quality gain.

## Dispositions (agreed form)
1. Targets become **weekly review SIGNALS discussed with the operator**, never automated pass/fail;
   the "unclassified work counts as Claude work" anti-gaming rule IS adopted.
2. Numeric quota reserves **deferred** until a real quota signal exists; the priority rules are adopted
   as policy (planning consults never preempt an active worker; below-20%-quota admission restriction
   is operator guidance).
3. plan_ref becomes a **spec-schema field required for new specs** via a follow-up high-assurance spec
   (grandfathering SPEC-001..015); the CI text-matching check is **deferred** to the 4-week review.
4. Fast path **amended**: also planless — conversational explanation/assessment answerable from
   existing session context with no new research, no state change, and no durable recommendation.
   Anything needing new research, producing an artifact, or recommending a decision → planned.

## Authorized (as drafted, unamended)
- Intake state machine (classify → Codex plan → record → challenge → authorize → delegate → reconcile
  deviations at completion) as a mandatory CLAUDE.md reflex.
- Ownership chain: **Codex drafts → Claude challenges (must name a concrete objection or why none
  applies) → Codex disposes/revises → Claude authorizes (digest-bound) → Codex executes → gates →
  independent Claude review → human/reserved merge.**
- Artifacts: `.orchestrator/plans/PLAN-NNN.md` (tracked, frontmatter + plan + challenge + disposition +
  authorization); specs reference their plan; decisions record authority, not duplicate plans.
- `--small` micro-plans (objective/scope/action/verification/rollback) for tiny tasks — planning
  requirement kept, length scaled.
- Deviation reconciliation at completion: followed / authorized deviation / unauthorized deviation;
  repeated unauthorized deviations fail process review even with green tests.
- Second fresh-context Codex critique before authorization for high-assurance plans.
- `scripts/codex-plan` wrapper (dispatched as SPEC-016, Codex-drafted spec, Codex-executed).
- Rollback is component-level via human-approved, time-boxed exceptions; never back to planless.

## Validation
Weekly delegation-report review with the operator (signals: plan coverage of substantive tasks,
Codex-drafted share of plans, risk-weighted work class by vendor, exception count). No automated
targets. First review: 2026-07-20.
