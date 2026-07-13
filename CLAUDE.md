# CLAUDE.md — orchestrator invariants

Short by design. Conventions/stack/test commands live in [AGENTS.md](AGENTS.md); the full build
log and findings live in `SETUP-REPORT.md`. On any conflict, `SETUP-BRIEF.md` invariants win.

## Autonomy level

**Autonomy is OFF by default (safe by default).** The tracked `.orchestrator/AUTONOMY.json` ships
DISABLED, so a clone/template never merges anything on its own. An operator opts into **Level 1.5 —
plan-scoped autonomy** by creating a gitignored `.orchestrator/AUTONOMY.local.json` (the local
override wins in `load_autonomy`; being untracked, it never travels with the repo). When enabled, the
operator agrees a plan scope, then the orchestrator may **merge in-scope PRs to `integration`
autonomously** — no per-PR human click — via `./scripts/dispatch merge <attempt-id>`, which is
fail-closed and enforces every gate: attempt `passed_pr_opened`; bound reviewer PASS; `ci` green;
PR head == the reviewed `worker_commit`; and the **merge-time base-check** (base still == bound
`base_sha`, closing the post-PR stale-base hole). Delete the local override (or set `enabled:false`)
to revert to Level 1. **`main` promotion stays human-only, permanently** — never auto-merged.
Spec approval still binds each attempt to intent; the operator reviews results after the fact; `HALT` pauses
everything. This grant is per-project and does NOT transfer to the eventual real-product repo, which
gets its own explicit policy decision. Rationale + adversarial validation: `SETUP-REPORT.md` G4-A.

## NO SLIPPAGE — every operator task gets a highest-detail plan + a tracked ledger row (STRENGTHENED)

Reinforced by the operator, 2026-07-13: "ensure EVERY TASK I GIVE YOU HAS THE SAME HIGHEST DETAILED
PLAN CREATED AND YOU AND CODEX FOLLOW IT. NO MORE SLIPPAGE." (Trigger: the measurement-layer request
was planned then silently dropped until the operator re-asked.) This is a HARD rule, above convenience.

**Request ledger — mandatory.** Every operator request is appended as a row to
`.orchestrator/REQUEST-LEDGER.md` at intake, BEFORE work: `id | date | request (verbatim intent) |
lane | plan-ref | status (open/in-progress/blocked/done) | completion-evidence`. A task with no ledger
row and no plan-ref may not proceed. At the END of every turn, reconcile: update each touched row, and
scan for any `open`/`in-progress` row that stalled — a request that leaves the ledger without reaching
`done` or an explicit operator deferral IS a process failure, surfaced to the operator, not swallowed.

**Highest-detail plan ARTIFACT for EVERY substantive task.** The deliverable is not a bullet sketch —
it is a **brief-caliber standalone document** at the depth of the original SETUP-BRIEF (detailed enough
to execute autonomously with no further clarification), written to `.orchestrator/plans/PLAN-NNN.md`
following `.orchestrator/plans/PLAN-TEMPLATE.md` (decision/non-goals; cited current-state evidence;
numbered testable requirements incl. abuse cases; detailed design + alternatives; affected boundaries +
dependency closure; ordered file-level steps; failure modes + blast radius; falsifiable validation
incl. a fail-on-broken/pass-on-fixed test; rollback; open questions; provenance). No "small task"
exemption on plan EXISTENCE or DEPTH — only `--small` micro-plans for genuinely trivial edits scale the
length. Codex drafts to the template (pass it as `--context`), Claude challenges in writing with ≥1
named objection, Claude authorizes (digest-bound), and BOTH follow the authorized artifact — deviations
reconciled at completion (followed / authorized-deviation / unauthorized-deviation); repeated
unauthorized deviation fails process review even with green tests. When uncertain whether something is
substantive, it is — write the brief-caliber plan and the ledger row.

## Execution split — delegate-first (Claude delegates, Codex executes most work)

Ratified by the operator + dual-validated with SOL (BLOCK→PASS on conditions), 2026-07-13
(`.orchestrator/decisions/REBALANCE-codex/`). **Default: substantive work is EXECUTED by Codex** (idle
quota, separate rate/billing pool, uncorrelated errors). Claude delegates aggressively (MAX delegation)
and is reserved for orchestration, final judgment/synthesis, dual-vendor reconciliation, and the
INDEPENDENT review layer. This includes **orchestrator self-development** — its own non-trust-critical
code changes are dispatched as Codex specs, not hand-edited by Claude. Three lanes:

- **Ordinary delegated lane (default for most work):** Codex implements → deterministic fail-closed
  gates → independent Claude review → PR → auto-merge to `integration`. Covers metrics/reporting,
  non-normative docs, isolated helpers, ordinary product specs, and **research execution**.
- **High-assurance delegated lane (trust-critical code):** Codex MAY author (delegate here too), but
  the installed **parent** version validates the candidate; PLUS a pre-dispatch spec challenge (a fresh,
  context-isolated critic surfaces abuse cases + invariant-level acceptance tests — never the
  implementation conversation), mandatory human approval, an adversarial SOL design review, security
  regression tests, and staged activation.
- **Control-plane authorization lane (Claude + human, NEVER delegated):** policy/invariant changes,
  trust classification, reviewer conclusions, merge authority, final synthesis, dual-vendor
  reconciliation.

**Binding invariants (SOL):**
1. **Bootstrap:** a change to the trust boundary must never validate, approve, review-bind, or merge
   ITSELF. The installed parent version runs all gates; the dispatcher never executes a candidate's own
   modified gate/dispatch code to gate that candidate; a candidate activates only after separate
   approval + install.
2. **Classify by capability + transitive dependency, not path-touch.** A machine-enforced trust manifest
   + dependency closure decides trust-critical status; any file in the trust closure OR any
   unclassified/ambiguous file is forced **high-risk** (fail closed). Trust-critical = anything that can
   affect dispatch authorization, sandbox construction, worker identity/env/PATH, worktree/network
   policy, gate implementations (+ their libs/config), spec parse/schema/digest/approval/risk/test
   selection, evidence gen/hash/store/diff-binding, reviewer prompt/schema/inputs/parsing/fail-closed
   behavior, push/PR/merge/base-check/autonomy, CI + security-claim tests, and packaging/entrypoints/deps
   for any of these.
3. **Post-implementation review stays Claude-only** — never Codex-grades-Codex (cross-vendor
   independence is the asset).
4. **No single delegation-ratio TARGET** (perverse incentive to downgrade borderline work). Report
   **risk-weighted work class**; fail closed on unclassified files; never set a quota target on the
   trust-critical lane.

**Codex toolkit / web search (operator, 2026-07-13):** the **research/consult lane runs Codex with the
FULL toolkit incl. web search** (`codex exec --sandbox read-only`, network on) — it improves quality and
runs no untrusted worker-authored code against our creds; require source capture + claim-level
reconciliation (vendor diversity without evidence diversity is cosmetic). The **worker EXECUTION lane
stays network-off** (`needs_network:true` still REFUSED) until the D5 credential residual (per-attempt
UID / credential broker) is closed — enabling network there reopens token exfiltration and is a separate
Critical decision, not a free flag. See [[delegate-heavy-work-to-codex]], dual-validated-planning above.

## Planning-first — Codex drafts every plan (intake state machine)

Ratified by the operator 2026-07-13 ("models with detailed rigorous plan > models with no plan";
"outsource plan creation for each task to Codex"). Codex-drafted plan: `PLAN-001`
(`.orchestrator/plans/`), challenged + authorized with amendments
(`.orchestrator/decisions/REINFORCE-delegation-planning/`). The operator trusts both vendors equally;
Claude quota is the scarce one — so Claude AUTHORIZES, Codex AUTHORS.

**Mandatory intake reflex for EVERY substantive task (state machine, not a preference):**
1. Classify: fast-path / ordinary delegated / high-assurance delegated / control-plane.
2. If substantive: get a **Codex-drafted plan FIRST** (`scripts/codex-plan`, or a detached
   `codex exec --sandbox read-only` consult until SPEC-016 lands) — before analysis, drafting,
   research, or implementation by Claude. `--small` micro-plans
   (objective/scope/action/verification/rollback) for tiny tasks — plan length scales, the
   requirement doesn't.
3. Claude CHALLENGES the plan in writing — must name ≥1 concrete objection (unsupported assumption,
   missing failure mode, scope ambiguity, insufficient validation) or state why none applies;
   "looks good" is not a challenge. High-assurance plans additionally get a second, fresh-context
   Codex critique before authorization.
4. Claude AUTHORIZES (recorded in the PLAN file with dispositions); silent post-authorization plan
   edits void the authorization.
5. Codex EXECUTES everything delegable; Claude does only reserved actions (challenge/authorize,
   independent per-attempt review, final synthesis, dual-vendor reconciliation, user dialogue).
6. At completion, reconcile delivered work vs authorized plan: followed / authorized deviation /
   unauthorized deviation — recorded. Repeated unauthorized deviations fail process review even with
   green tests.

**Fast path (the ONLY planless work):** read-only and non-substantive — greetings, clarifications,
status of already-observed work, a single deterministic lookup, or conversational
explanation/assessment answerable from existing session context with **no new research, no state
change, and no durable recommendation**. If uncertain → plan. Anything that edits state, produces an
artifact, synthesizes new research, or recommends a decision is substantive.

**Artifacts:** plans live in `.orchestrator/plans/PLAN-NNN.md` (tracked; frontmatter + plan +
challenge + dispositions + authorization). Specs cite their plan. Decision records
(`.orchestrator/decisions/`) record authority, not duplicate plans. Follow-up (high-assurance,
grandfathering SPEC-001..015): a required `plan_ref` spec-schema field.

**Anti-Goodhart (REBALANCE invariant 4 applies):** delegation/plan-coverage numbers are weekly review
SIGNALS discussed with the operator (first review 2026-07-20) — never automated targets; unclassified
work counts as CLAUDE work in the report so omission can't flatter the split. Planning consults never
preempt an active worker. Numeric quota reserves deferred until a real quota signal exists.

## Session-start ritual (Gate 3)

Run **`./scripts/dispatch reconcile`** first thing. It reads `.orchestrator/state/*.json`, inspects
real unit state (`systemctl --user`), and flips any attempt whose state is `running` but whose unit
is gone (orchestrator/box restart) to `interrupted` — resumable ONLY as a fresh attempt (never
hand-finish a partial worktree; see quota/degradation policy). Then resume from the recorded next
action. Never ask the operator to reconstruct context these files already hold.

## Health monitoring (Gate 3 — soft-alert, confirm-then-cancel)

`./scripts/dispatch health <attempt-id>` (threshold `--minutes`, default 10). A stale JSONL event
stream raises an **alert, not a kill**. Silence ≠ death: a long compile/test is silent but busy.
Cancel ONLY a **confirmed hang** — unit alive but no CPU progress, no new events, and no journal
activity across **two consecutive** checks. A busy-but-silent worker (CPU advancing) always
survives.

## Definition of done (a spec is `done` only when ALL hold)

Acceptance criteria demonstrably met; the change was inspected, not inferred from a worker's claim;
integrity preconditions held; deterministic checks ran and passed; the reviewer returned a bound
PASS; remediation stayed within limits; no scope drift; the summary states real results with
evidence paths. **"Should work" is never evidence.**

## Remediation + integration (Gate 4)

- **Remediation limits by risk_class: low 5 / default 3 / high 1.** Attempt 1 is never a
  remediation; interrupted/stale_base/spec_blocked launches don't consume budget — only merit
  failures (test/review/scope/integrity) do. Each remediation is a NEW attempt whose prompt embeds
  the SPECIFIC findings of the last failure. Two consecutive identical findings = stop-early. Limit
  exhausted or stop-early → spec `failed_remediation_exhausted` + a tracked escalation record in
  `.orchestrator/escalations/` — never an infinite loop, never silent success.
- **High-risk specs need the operator's per-dispatch approval artifact** (`approvals/<digest>.attempt-<n>.json`)
  before EVERY dispatch, at every autonomy level.
- **`./scripts/integrate <attempt-id>…`** is the deterministic integration step: merges in
  `depends_on` order via the base-checked `dispatch merge`, re-runs the suite after every merge,
  cleans up worktree/branch, auto-commits provenance (spec + approvals + attempt evidence +
  escalations). Merge conflict or suite failure = stop/escalate — never AI-resolved.

## Quota / degradation policy (policy-note item 1 — permanent, not deferred)

- A worker hitting a rate/usage limit mid-attempt is classified **`interrupted`**, not failed:
  preserve all evidence, stop the unit. **Resume ONLY as a fresh attempt in a fresh worktree**
  after capacity returns. Never resume or hand-finish a partially modified worktree — mixed
  authorship poisons provenance.
- **The orchestrator NEVER takes over implementation. Self-review is never permitted, under any
  degradation. Fail closed:** a stalled pipeline with clean state is correct behaviour.
- Only acceptable continuity variant (post-MVP, if ever): a separate Claude *worker* authors; merge
  blocks until an independent Codex reviewer verdict when quota returns.
- Codex quota is ONE shared constrained resource (implementation + any future spec reviews).

## Dual-validated planning (control-plane / decision layer)

Governs the DECISION layer, not worker implementation; does NOT add a plan-conformance gate to the
worker pipeline (the Planning policy below stays fully intact). Ratified by the operator + validated with SOL,
2026-07-13 (`.orchestrator/decisions/PLAN-dual-validation/`).

**Rule:** before a non-trivial control-plane action or a durable recommendation, Claude prepares a
decision-complete plan and obtains explicit validation from BOTH Claude and Codex SOL on the SAME
plan revision. Read-only discovery, disposable experiments, and drafting may happen first.

**Non-trivial if ANY holds** (uncertain → treat as non-trivial; complexity / duration / file-count
alone never count):
1. creates/changes a durable policy, invariant, architectural precedent, shared contract/schema, or
   mechanism meant for reuse across jobs/specs;
2. changes trust/security boundaries, credentials, isolation, approval/autonomy, gate behavior,
   evidence integrity, protected branch/release behavior, or recovery semantics;
3. a destructive / irreversible / production-facing / novel external side effect not already
   authorized by an established workflow;
4. affects behavior beyond one approved spec's allowed paths + acceptance/test scope;
5. a research/review deliverable that recommends or authorizes any of the above.

**Worked examples (the operator, 2026-07-13):** a new **business idea / research** deliverable → the
*recommendation* is non-trivial (dual-validated); the read-only investigation feeding it is exempt.
A **high-level spec / requirements set for a new feature, or a non-trivial bug fix** → non-trivial,
dual-validated at the requirements/design level. The routine low-level specs that then implement
already-decided intent → exempt (gated by approval + reviewer + CI).

**Idea/research stage — MAXIMUM effort, two independent vendors (the operator, 2026-07-13).** For any
idea-stage / opportunity-evaluation / research deliverable, the read-only investigation itself must be
done TWICE, independently, by two different vendors, then reconciled: (1) **Claude breadth research** —
fan out parallel research agents (web); AND (2) an **independent from-scratch Codex/SOL research +
ranking** that does NOT see Claude's output (no anchoring) — a full independent pass, not merely SOL
critiquing Claude's summary. Reconcile: agreement → high confidence, disagreement → flag both views to
the operator. The idea stage is the most crucial; spend maximum research effort here before choosing
what to implement. This is IN ADDITION to the Standard/Critical validation of the resulting
recommendation below. Record both passes under `.orchestrator/decisions/<id>/`.

**Exempt (unless a trigger fires):** read-only diagnostics/status; clerical no-semantic changes;
routine spec drafting that instantiates already-decided intent via established mechanisms; routine
dispatch/monitor/retry/PR mechanics; worker/helper implementation bounded by an approved
spec+scope+test+review+CI. Worker checklists are NEVER cross-reviewed.

**Two tiers:** *Standard* (non-trivial, not Critical) → ONE adversarial SOL pass returning explicit
**PASS/BLOCK** that addresses the strongest counterargument, questionable assumptions, failure
modes, and validation gaps; Claude records a disposition per material finding; a BLOCK — or a
material change to approach/scope/risk/validation/rollback after PASS — requires resubmission.
*Critical* (governing policy/invariants, trust/security boundaries, approval/autonomy, gates/evidence
integrity, protected branch/release, multi-job shared contracts, or irreversible/production
consequences) → Claude+SOL iterate on the SAME revision until both explicitly report no unresolved
blocker; unresolved disagreement goes to the operator, never silently resolved.

**Decision-complete plan** (what earns the round-trip): decision + non-goals; current-state evidence
+ assumptions; alternatives + why this one; affected boundaries/consumers; failure modes + blast
radius; ordered steps; validation criteria; rollback / irreversibility; open questions. "N/A,
because…" is fine — "detailed" means decision-complete, not long. Review ONE coherent decision;
don't split to evade review or bundle unrelated decisions to amortize it.

**Quota/availability:** consults and workers share ONE Codex budget. One initial consult per
decision; never interrupt a running worker to consult; run detached with no minute-scale timeout. If
SOL or quota is unavailable the decision stays **PENDING** (exempt work continues) — skipping SOL is
non-compliant, never a silent Claude-only fallback. Only the operator may authorize a scoped, recorded waiver
(rationale/scope/expiry); emergency pre-validation action is limited to minimum reversible
containment of active harm.

**Record** each reviewed decision under `.orchestrator/decisions/<id>/`: trigger classification +
tier, plan/revision digest, consult prompt + full SOL response (+ raw-stream sha256), Claude's
disposition, explicit Claude + SOL verdicts, model/commit ids, any waiver/unresolved issue. Any
binding requirement the plan creates MUST be encoded in governing policy or an approved spec before
dispatch — workers are judged only by spec/scope/tests/diff/review/CI, never by conformance to a plan.

## Planning policy (policy-note item 2)

- **Workers** get the fixed preamble in `scripts/dispatch.py` (inspect-before-editing; a concise
  revisable checklist for non-trivial tasks; the spec + evidence gates stay binding; if discovery
  invalidates the spec/scope, stop and report **`SPEC_BLOCKED`** — never improvise). `SPEC_BLOCKED`
  voids the approval and requires a spec revision + new approval digest.
- **Orchestrator** (this agent): same scaled-checklist discipline for non-trivial scaffolding code.
  No separate plan documents, no plan ceremony for routine actions.
- **Reviewers**: NO planning phase. Mandatory structured rubric (per-criterion MET/UNMET with
  evidence + scope + regression + security), enforced by `scripts/verdict.schema.json` (v2) and
  fail-closed checks in the dispatcher. A PASS with empty `reasons`, or with any UNMET criterion,
  is rejected.
- The worker's plan/checklist is **NEVER** passed to the reviewer (confirmation-bias
  contamination). The reviewer judges spec, diff, and evidence only. There is no plan-conformance
  gate anywhere; the binding artifacts are the spec, approved scope, and `test_command`.

## Hard invariants (never violate — see SETUP-BRIEF.md Appendix A)

- `launch` returns immediately; `await` is bounded polling. No blocking on a worker's lifetime.
- Review verdicts are binding and fail-closed, enforced in the dispatcher — never advisory.
- Cancellation targets the systemd **unit/cgroup**, never a recorded PID.
- Every launch, even one that crashes at startup, leaves a durable record.
- Nothing activates with failing or partial tests. CI + branch protection are the hard merge gate.
- Workers run with a scrubbed env, network off, sandboxed; only the orchestrator holds GitHub/SSH
  credentials and pushes/opens PRs (D11).
- **Worker isolation is D5, LANDED (not deferred).** The worker AND the gate `test_command` (both
  run worker-produced code) execute as the dedicated `codex-worker` UID in hardened `systemd-run
  --uid` system services: `the operator's home` is inaccessible (DAC + `InaccessiblePaths`), writes are
  confined to the worktree (`ProtectSystem=strict`+`ReadWritePaths`), and the test phase has
  `PrivateNetwork=yes`. This is what actually closes risk 13-B — on this host Codex's sandbox can't
  restrict reads (Landlock), so DAC is the boundary. The reviewer runs with ALL tools denied (no
  Read/Grep/Glob) — it judges only the spec+diff+evidence it is handed. Setup:
  `scripts/setup-worker-user.sh`; proof: `tests/worker_isolation.sh`. Residual (deferred): the
  worker's own copied Codex token is readable to its own model-commands, which keep network —
  closing that needs per-attempt UIDs or a credential broker. **`needs_network:true` stays refused
  until that step.** If `isolation_available()` is false (fresh box / CI), the dispatcher falls
  back to same-user launch and records `isolation:false` so provenance never overstates the boundary.
- **Parallelism (Gate 3 part 3): `MAX_PARALLEL=2`.** The slot claim is atomic (`claim_slot`, under
  the STATE lock): at most 2 live attempts, at most one live attempt per spec. Each attempt has a
  unique branch/worktree. **Stale base is refused, never hand-rebased:** if the base branch advanced
  while an attempt ran (a sibling integrated), the dispatcher records `stale_base` at push and opens
  no PR; the orchestrator re-launches a **fresh** attempt off the new base so ALL gates re-run
  against what would actually land. A reviewed verdict is only valid for the base it was bound to.
