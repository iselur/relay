# SECURITY — what actually holds, and what does not yet

This file is the source of truth for the security model. Security claims come in three kinds and
README/CLAUDE.md may not state one as stronger than its kind: **tested guarantees** (a CI/box test
proves them), **configured assumptions** (set up outside this repo, verified manually), and
**known gaps** (stated, queued, not defended). Gaps stay listed until a shipped fix closes them.

## Tested guarantees

| Guarantee | Proof |
|---|---|
| Worker commands cannot traverse the owner's home directory, and the credential files the drill checks there (GitHub token, Claude and Codex logins, SSH key) are unreadable — an enforced home boundary, not an enumeration of every possible secret | `tests/worker_isolation.sh` (box-only) |
| No isolation → no launch; launching unisolated requires an explicit override variable, and its use is recorded in the evidence | `tests/isolation_fail_closed.sh` |
| A missing, skipped, or empty test result fails the gate before review; worker-edited required tests are restored from the orchestrator's checkout before grading (detection against accidental skips — see gap 3 for the malicious case) | `tests/test_attestation.sh` |
| A worker holding fake root inside its own user namespace still cannot read or write the owner's home; the userns exception is the packaged capability-stripping AppArmor profile, not the global sysctl | `tests/worker_userns.sh` (box-only) |
| The Codex runtime bind-mounted into the worker service (npm package tree or native binary) is vetted before launch and re-vetted in `_run`: root/operator-owned, not world-writable, group-writable only when the group is operator-private, no named POSIX ACL, no symlink escaping the tree; resolved real paths are bound and every mounted byte plus the host interpreter is fingerprinted so a change between check and run is refused | `tests/codex_runtime.sh` |
| Worker changes outside the spec's declared scope are rejected | `tests/dispatch_gate4.sh`, `tests/scope_glob.sh` |
| A verdict is bound to the exact diff and base; a stale base is refused | `tests/dispatch_gate4.sh` |
| The rulebook and repo prose cannot silently grow back | `tests/rulebook_cap.sh`, `tests/prose_cap.sh`, `tests/plain_language.sh` |
| Review rounds are capped at three per topic, in code (and only round-N.md files count as rounds), and the Codex-run reviewer refuses Codex-authored artifacts | `tests/review_cap.sh` |

## Configured assumptions (outside this repo; verify during bootstrap and after any GitHub change)

- Direct pushes to `main` are rejected; `ready-for-main` requires a PR with the `ci` check green —
  GitHub ruleset, not a repo test.
- Ubuntu's `bwrap-userns-restrict` AppArmor profile is installed and enforcing (host setup, not a
  repo test — `tests/worker_userns.sh` fails if it is absent). It lets Codex build its own sandbox
  on Ubuntu 24.04. The profile is attached to the `bwrap` program, so the worker user can run
  `bwrap` too: a deliberate trade the owner accepted on 2026-07-14. It restores Codex's own
  file and network confinement and leaves Ubuntu's system-wide restriction in place for everything
  else; the cost is that any program on this box that runs `bwrap` reaches more of the operating
  system's isolation machinery than before. `tests/worker_userns.sh` proves the worker still
  cannot reach the owner's home through it.
- Approvals bind to the spec digest and instance identity; the reviewer runs with all tools
  denied; autonomy applies only to `dispatch merge` — enforced by `scripts/dispatch.py` code
  paths that the repo suite exercises only partially.

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
3. **The test grade is produced inside worker-writable territory.** The per-test result file lives
   in the worktree, and `scripts/test` itself is not part of the restored required set — a worker
   that edits the runner could in principle forge its own grade. Until the grader moves fully
   outside the worker's reach, the tests-must-run gate is protection against accidental skips and
   honest failures, not against a deliberately malicious worker.
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
