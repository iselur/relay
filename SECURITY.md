# SECURITY — what actually holds, and what does not yet

This file is the source of truth for the security model. Security claims come in three kinds and
README/CLAUDE.md may not state one as stronger than its kind: **tested guarantees** (a CI/box test
proves them), **configured assumptions** (set up outside this repo, verified manually), and
**known gaps** (stated, queued, not defended). Gaps stay listed until a shipped fix closes them.

## Tested guarantees

| Guarantee | Proof |
|---|---|
| External-CLI worker commands cannot traverse the owner's home directory, and the credential files the drill checks there (GitHub token, Claude and Codex logins, SSH key) are unreadable — an enforced home boundary, not an enumeration of every possible secret. Subagent workers are OUTSIDE this guarantee by design: see the configured assumption below | `tests/worker_isolation.sh` (box-only) |
| No isolation → no launch; launching unisolated requires an explicit override variable, and its use is recorded in the evidence | `tests/isolation_fail_closed.sh` |
| Execution modes come from one fail-closed manifest; each required test must literally PASS in its assigned phase with subject, identity, hashes, timestamps, and logs, and a box PASS is never upgraded into candidate evidence | `tests/test_attestation.sh`, `tests/execution-policy.tsv` |
| A worker holding fake root inside its own user namespace still cannot read or write the owner's home; the userns exception is the packaged capability-stripping AppArmor profile, not the global sysctl | `tests/worker_userns.sh` (box-only) |
| The Codex runtime bind-mounted into the worker service (npm package tree or native binary) is vetted before launch and re-vetted in `_run`: root/operator-owned, not world-writable, group-writable only when the group is operator-private, no named POSIX ACL, no symlink escaping the tree; resolved real paths are bound and every mounted byte plus the host interpreter is fingerprinted so a change between check and run is refused | `tests/codex_runtime.sh` |
| Dispatcher Python tests use a separately provisioned root-owned runtime under `/opt`, bound read-only into the hardened candidate service; the box drill proves it is root-owned and refuses worker writes (the run-time fingerprint re-check lives in `trusted_test_runtime`, not this drill) | `scripts/setup-worker-user.sh`, `tests/worker_isolation.sh` (box-only) |
| Worker changes outside the spec's declared scope are rejected | `tests/dispatch_gate4.sh`, `tests/scope_glob.sh` |
| A verdict is bound to the exact diff and base; a stale base is refused | `tests/dispatch_gate4.sh` |
| The rulebook and repo prose cannot silently grow back | `tests/rulebook_cap.sh`, `tests/prose_cap.sh`, `tests/plain_language.sh` |
| Review rounds are capped at five per topic, in code (and only round-N.md files count as rounds), and the Codex-run reviewer refuses Codex-authored artifacts | `tests/review_cap.sh` |

## Configured assumptions (outside this repo; verify during bootstrap and after any GitHub change)

- Direct pushes to `main` are rejected; `ready-for-main` requires a PR with the `ci` check green —
  GitHub ruleset, not a repo test.
- Both protected branches also require a PR's branch to be up to date with its base before merge
  (GitHub strict status-check policy, enabled 2026-07-16), so a green `ci` verdict always ran
  against the base that is actually being merged into — again a GitHub setting, not a repo test.
- Ubuntu's `bwrap-userns-restrict` AppArmor profile is installed and enforcing (host setup, not a
  repo test — `tests/worker_userns.sh` fails if it is absent). It lets Codex build its own sandbox
  on Ubuntu 24.04. The profile is attached to the `bwrap` program, so the worker user can run
  `bwrap` too: a deliberate trade the owner accepted on 2026-07-14. It restores Codex's own
  file and network confinement and leaves Ubuntu's system-wide restriction in place for everything
  else; the cost is that any program on this box that runs `bwrap` reaches more of the operating
  system's isolation machinery than before. `tests/worker_userns.sh` proves the worker still
  cannot reach the owner's home through it.
- Subagent workers (today: any claude-vendor worker model) BUILD inside the orchestrator's own
  session and trust domain — the operator context, with its tools and credentials. There is no
  isolated Claude worker process: 2026 Anthropic terms keep subscription auth inside first-party
  surfaces, and the owner chose subagent mode over an API-key side channel (2026-07-16). What
  protects the repo is the unchanged grading half that `dispatch continue` runs — path-safety,
  orchestrator commit, integrity, scope, the isolated network-off test phase, required-test
  attestation, bound review — plus the resolution-time refusal of same-model self-review.
  Process isolation is claimed for external-CLI workers only (`tests/dispatch_subagent_worker.sh`).
  BUILD model provenance is an orchestrator-written receipt (`raw/subagent-receipt.json`;
  `dispatch continue` refuses a missing receipt or one naming a model other than the frozen
  worker model) — an attestation inside the same trust domain, not third-party proof.
- Approvals bind to the spec digest and instance identity; a CLAUDE bound reviewer runs with
  all tools denied (a CODEX bound reviewer has no tool-denial flag: its read-only sandbox
  limits only model-spawned shell commands, so as an operator subprocess it keeps codex's own
  file-read surface — an accepted, permanent residual of the vendor-general reviewer); autonomy
  applies only to `dispatch merge` — enforced by `scripts/dispatch.py` code paths that the repo
  suite exercises only partially.

## Known gaps (fixes queued in `.orchestrator/BACKLOG.md`)

1. **The worker holds its own Codex login and has network in the build phase.** Setup copies Codex
   auth into the worker's home so the worker can run Codex at all, and the build-phase service is
   not network-blocked (the test phase is). Model-produced commands therefore share an environment
   with readable Codex login files and a network path out. The owner's own credentials remain
   unreachable — but "workers get no network / no credentials" is not yet true and is not claimed.
2. **Approvals record intent; they do not prove a human.** An approval is a JSON file; the
   isolation override is an environment variable. Software running as the owner could create
   either — a test can prove the file or variable must be present, never who set it. They are an
   audit trail, not an authorization boundary. A mechanism software on this box cannot fabricate
   (e.g. GitHub environment approval or a separate human-held account) is the planned replacement.
3. **Installed tests do not make malicious candidate code a trustworthy witness.** The dispatcher
   collects phase exits and logs outside the worktree and prevents candidate edits to the installed
   test script, but an isolated test intentionally imports or executes candidate code. Malicious
   candidate code can terminate, hang, or manipulate that test process and may still forge a
   semantically misleading success. The gate prevents runner/test replacement and phase flattening;
   it does not claim a human-unforgeable grade. The required suite, its manifest, and every grader's
   bytes are now derived from the pinned git tree and executed from a fresh checkout **outside** the
   working tree (`dispatch.py: materialized_grader_tree`), so no grade opens a mutable working-tree
   path; the residual is a same-uid owner racing that temp checkout itself — deferred to backlog
   item 6 ("move the grade fully outside candidate/operator influence"), not closed here.
4. **Evidence is an audit record, not immutable.** Attempt files and their hashes are ordinary
   files owned by the account that writes them. Treat them as good-faith provenance.
5. **The dispatcher currently targets this repository.** Pointing workers at an arbitrary product
   repo is planned but not yet a tested interface.
6. **Runtime trust assumes a single-trust-principal box.** The Codex-runtime vetting (above) proves
   the mount source is writable only by root or the operator, and rejects named ACLs and
   world/group-writable paths. Two residuals remain, out of the deployment threat model — a
   private VPS whose only accounts are the owner, root, and the confined `codex-worker`, with the
   runtime under the owner's home (unreachable by the worker): (a) `_group_is_private()` reads
   group membership via NSS; a directory service that disables enumeration (e.g. SSSD) could hide a
   user who shares the owner's primary group, so a *group-writable* runtime could be writable by
   another principal. Keep the runtime non-group-writable, or owner-private-group, on a multi-user
   box. (b) The final millisecond-scale window between the last check and systemd resolving the
   mount is accepted for sources proven writable only by root/operator. Both close only matter if a
   second, non-trusted human account exists on the box; neither is exploitable in the single-owner
   model this system is built for.

## Scope

Single-owner system on a private VPS. No external vulnerability reports are expected; if you
run a copy and find a hole, open an issue on the template repo.
