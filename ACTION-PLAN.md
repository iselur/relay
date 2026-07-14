# ACTION-PLAN — post-audit hardening (2026-07-13 self-reflection)

Source: two-vendor blind audit, `.orchestrator/decisions/SELF-REFLECT-2026-07/` (on the box; not in
this clone). Operator decisions: KEEP built capacity, re-audit 2026-07-27; do NOT pause; proceed in
priority order.

## Lane split (IMPORTANT)
This tracker holds ONLY the **non-sensitive, code/doc items safe for an unsupervised cloud session**.
Each is done as a **draft PR to `integration`, never merged by the automation** — an on-box session +
human authorize and merge. Trust-boundary items (isolation, credentials, sudoers, authority
separation, approval schema, evidence hashing) are deliberately NOT here — they require the box +
dual-validation and are handled on-box.

## Cloud-safe items (do ONE per run; skip if an open `auto/*` PR already exists)
- [x] **A. CI runs the real tests.** In `.github/workflows/ci.yml`: install pinned `pyyaml` +
  `jsonschema` so `tests/dispatch_gate4.sh` / `dispatch_parallel.sh` / `worker_isolation.sh` actually
  execute instead of SKIP-passing; and add a top-level `permissions: contents: read` plus
  `persist-credentials: false` on `actions/checkout`. Acceptance: a CI run executes the dispatcher
  tests (not SKIP); the workflow declares least-privilege permissions.
- [ ] **B. Truth-in-docs.** Remove or redirect every dangling reference to `SETUP-BRIEF.md` /
  `SETUP-REPORT.md` (they exist in no commit) across `CLAUDE.md`, `AGENTS.md`, `.gitignore`,
  `scripts/integrate`, `scripts/dispatch.py`, `specs/spec.schema.json`; fix the `MAX_PARALLEL` drift
  (docs say 2, code defaults 3 — make docs say "configurable, default 3"); mark the trust-manifest and
  `plan_ref` as "NOT YET BUILT" wherever CLAUDE.md calls them binding. Acceptance: no reference to a
  nonexistent file; MAX_PARALLEL consistent; no prose claims a mechanism that has no code.
- [ ] **C. `cmd_await` cap from ceiling.** `scripts/dispatch.py` `cmd_await` hard-caps `max_wait` at 8h
  while `hard_ceiling_hours` allows 24 — derive `max_wait` from the attempt's `launch.json` ceiling +
  margin. Acceptance: awaiting a 24h-ceiling attempt does not die at 8h.
- [ ] **D. Glob scope tightening.** `_match_glob` uses `fnmatch` whose `*` crosses `/`; make `*` not
  cross `/` (trailing `/**` keeps recursive semantics) and add a `tests/dispatch_gate4.sh` case proving
  `dir/*.sh` does not match `dir/nested/evil.sh`. Acceptance: the new test passes; existing scope tests
  stay green.
- [ ] **E. `reconcile` observability.** Make `reconcile` also report orphaned `codex/*` branches +
  worktrees with no matching attempt record, and terminal-failed specs with no successor attempt
  (read-only reporting only — no deletion). Acceptance: a stale branch with no attempt dir is listed.

## On-box only (do NOT attempt in the cloud) — tracked for the operator
Isolation fail-open refusal; scoped sudoers wrapper + worker MemoryMax/TasksMax; credential broker;
machine-account authority split + required base/review status check on all merge paths; approval/grant
schema; launch-time snapshot + hash-all-terminal-evidence + reconcile GC; reviewer-value seeded-defect
experiment; metrics-semantics fix; real-workload validation.
