---
type: product-brief
status: selected
blocked_by: []
---

# Legacy Subsystem Rescue

## Outcome

Owner request, verbatim:

> The selected first product direction is Legacy Subsystem Rescue: given one external brownfield repository and one bounded desired or broken behavior, produce characterization evidence and a minimal reviewed, CI-green repair PR.
>
> Do not choose or invent a customer repository—the repository and target behavior are product inputs.

The user is the maintainer accountable for a brownfield repository who needs one uncertain or broken behavior repaired without first understanding or modernising the whole subsystem.

Their job is: “When one bounded behavior in a legacy subsystem blocks me, establish what the code does now, protect the relevant boundary with a test, and return the smallest safe repair as a PR I can review.”

The observable product result is one pull request against the supplied repository. It binds the exact base and head commits to characterization evidence, a minimal repair, an independent review, and green required CI. Relay does not select the repository, infer an unbounded problem, merge the PR, or claim production impact.

## Scope and non-goals

Product promise: for an admissible repository and behavior input, Relay will either produce the repair PR described above or return a checkable stop result naming the first unmet gate. It will not hide a failed attempt behind a plausible patch.

Required owner inputs:

- Git repository URL, destination branch or ref, and repository access.
- One bounded behavior contract: current observation, desired result, and a concrete example or reproducer.
- Allowed change paths, forbidden paths, risk constraints, and any repository-local contribution rules.
- Pull-request destination and the human or team who owns the repository decision.
- A credential handle supplied through the trusted boundary, with only the repository permissions listed below; never a credential value in the brief or worker prompt.

Inputs Relay must derive and freeze before editing:

- The immutable base commit resolved from the supplied destination ref.
- Exact bootstrap, reproduction, targeted-test, full-test, and required-CI commands, with expected exit behavior, taken from repository documentation and configuration or confirmed with the owner when they conflict.
- Required CI check names and their current state for the resolved base.

Outputs:

- An intake record with the supplied input digests, resolved base commit, start/end times, and gate outcomes.
- Baseline evidence: exact reproduction command, exit status, and complete redacted output at the base commit.
- A focused characterization or regression test that demonstrates the behavior boundary.
- The smallest repair that makes that test and the supplied required tests pass.
- A review verdict bound to the exact base, head, diff, and test evidence.
- An unmerged PR whose head equals the reviewed commit and whose named required CI checks are green.
- On failure, a stop result with retained evidence and no claim that a repair was produced.

Non-goals:

- Choosing, inventing, or bundling a demonstration/customer repository.
- Discovering a problem when no bounded behavior is supplied.
- General subsystem modernization, cleanup, dependency upgrades, framework migration, or speculative refactoring.
- Multi-repository changes, broad language support, or a generic external-repository plugin system.
- Changing deployment, infrastructure, CI workflows, repository settings, permissions, or secrets.
- Merging, deploying, releasing, monitoring production, or proving business impact.
- Guaranteeing a repair when the behavior cannot be reproduced, the repository cannot be built safely, or the required checks cannot complete within the pilot constraints.

## Frozen decisions

- **Direction:** Legacy Subsystem Rescue is the first external product proof. Reopen only if an admissible pilot shows that a bounded repair PR does not test Relay's intended product value, or the Owner changes the direction.
- **Inputs, not examples:** the external repository and target behavior are supplied at run time. Reopen only if the product changes from customer-directed repair to product-led discovery.
- **End state:** success is characterization evidence plus one minimal, independently reviewed, CI-green PR. Reopen only if the repository owner explicitly changes the delivery contract.
- **Narrow first proof:** one repository, one base commit, one behavior, one repair branch, and one PR. Reopen breadth only after this proof fails for a breadth-related reason or a second concrete product requires a different path.
- **No promotion authority:** Relay stops at an unmerged PR. Reopen only through an explicit Outcome Contract granting merge or deployment authority.
- **Timeboxed falsifier:** the first complete pilot has a 90-minute wall-clock budget after input admission. Reopen the budget only from measured pilot evidence, not because setup work expanded.

## Assumptions

- The supplied repository uses Git and accepts pull requests. Input admission verifies both rather than treating them as universal product support.
- The supplied behavior is narrow enough to reproduce with one exact command and protect with one focused automated test. A failed reproduction rejects the input for this slice.
- The repository has a discoverable build/test path and required CI that normally completes within the remaining 90-minute budget. The intake record captures the source and observed timing of every derived command.
- The repository owner permits the supplied path scope and repair branch. Authorization is an input; repository visibility alone is not authorization.
- The pilot repository is owner-authorized and not intentionally hostile. Arbitrary untrusted third-party repositories are excluded because the current worker boundary does not prove that a credential-bearing model process is safe against hostile repository instructions.
- A minimal repair exists without changing CI workflows, secrets, repository settings, or deployment. If not, this slice stops rather than silently widening authority.

Each assumption is tested at intake or by the earliest proof. A failed assumption produces a stop result; it does not authorize platform work.

## Minimal existing path

The closest installed Relay path was probed at commit `b273a603995a173c91d815f10b0e3c3c5b0199f7`.

- Exact argv: `python3 scripts/dispatch.py --help`
- Repository inputs consumed: `scripts/dispatch.py` (`sha256:74e3e0ccb77c7efe4d04e3936fb94c2fa20c8d26e5bf7300a3b7a9b7399264c3`) and its imported `scripts/vendor_adapters.py` (`sha256:1f862bd40bacf3e6374cb22c37f794c33952bf963a7242e2bddad472f8a474c5`)
- External product inputs consumed: none; no repository or target behavior was supplied, by Owner instruction.
- Exit status: `0`
- Complete output:

```text
usage: dispatch [-h]
                {launch,status,cancel,timeout,merge,continue,_run,_grade,await,health,reconcile,integrate}
                ...

positional arguments:
  {launch,status,cancel,timeout,merge,continue,_run,_grade,await,health,reconcile,integrate}

options:
  -h, --help            show this help message and exit
```

The missing capability is not a larger command surface. The installed dispatcher fixes its root to the Relay checkout and accepts a local spec identifier, not an external repository, immutable target base, and behavior contract. `SECURITY.md` also records that arbitrary product repositories are not yet a tested interface.

Fastest path: run the first pilot as a deliberately manual product operation using existing Git/GitHub, isolated editing, secretless test execution, and exact-diff review. Build no adapter first. If that path satisfies the Definition of done, no Relay code is authorized.

Deletion test: delete every proposed new component, manifest field, wrapper, database, dashboard, or abstraction and retry with the supplied repository commands plus existing Git/GitHub and review tools. If the exact Definition of done still holds, omit it. New installed code is justified only by a recorded pilot failure that the manual path cannot safely or repeatably bridge.

## Earliest falsifiable proof

Run one owner-supplied admissible repository and behavior through the whole loop before changing Relay:

1. **Minute 0–10:** validate inputs, resolve and record the immutable base, create a disposable worktree, and prove the secretless execution boundary. Stop if any input or boundary is missing.
2. **Minute 10–25:** run the exact reproducer and the narrowest relevant existing test at the base. Stop if the stated behavior is not observed for the stated reason.
3. **Minute 25–45:** add one focused characterization/regression test. Demonstrate that it fails at the base for the intended behavior, not because of setup.
4. **Minute 45–65:** make the smallest in-scope repair. No adjacent cleanup.
5. **Minute 65–78:** run the focused test and the supplied required suite; record exact commands, statuses, and redacted output.
6. **Minute 78–85:** obtain an independent review of the exact base-to-head diff and evidence; revise only for a material acceptance-relevant finding.
7. **Minute 85–90:** push one repair branch, open the PR, and confirm its required CI checks are green at the reviewed head.

The approach is falsified for this slice if an admitted input cannot complete all seven steps inside 90 minutes. The result is then the stop evidence and measured bottleneck, not a new framework or a relaxed claim. CI queue time counts; a repository whose normal CI cannot fit is not admissible for this first proof.

## Slices

1. **One external repair PR — first and only implementation slice.** It proves the product promise end to end on the supplied repository: bounded intake, characterization, minimal repair, independent review, and green CI at one exact head.

One slice is intentional. Splitting characterization, repair, review, or publication across Relay PRs would test internal scaffolding rather than the external user outcome. Any reusable Relay capability is a later slice only after the manual proof records the precise gap that requires it.

## Gates

1. **Input admission.** Proof: an intake record containing every required input, its digest or immutable identifier, and the resolved base. Arbiter: repository owner for intent and the trusted control boundary for completeness. Failure: stop before checkout and ask for the missing input.
2. **Repository authority and isolation.** Proof: scoped credential metadata plus a disposable execution record showing no owner-home mount, no secret mount, and network disabled while target code runs. Arbiter: trusted control boundary. Failure: stop; never use an unisolated override.
3. **Baseline reproduction.** Proof: the supplied reproducer at the exact base with complete redacted output and expected failure/observation. Arbiter: deterministic command result against the behavior contract. Failure: stop and return a mismatch; do not reinterpret the behavior.
4. **Characterization.** Proof: the candidate test fails against the base for the intended assertion and passes against the candidate. Arbiter: deterministic test runner. Failure: revise the test once; then stop if the behavior still is not isolated.
5. **Repair.** Proof: the focused test and supplied required suite exit `0`, while `git diff --name-only <base>..<head>` stays within the allowed paths. Arbiter: deterministic grader. Failure: revert the attempted repair or return the failing evidence; do not widen scope.
6. **Independent review.** Proof: a fresh reviewer returns a structured `PASS` bound to the exact base, head, diff digest, and evidence digest. Arbiter: the configured reviewer; only material, acceptance-relevant findings block. Failure: one surgical revision and fresh evidence, or a stop result when the 90-minute cap is reached.
7. **PR and CI.** Proof: the repository host reports the PR target, reviewed head SHA, and every named required check as successful. Arbiter: repository host plus trusted control boundary. Failure: do not claim success and do not merge; return the PR as incomplete or close it at the owner’s direction.

## Verification

Acceptance is deterministic when all of the following are true:

1. The intake record identifies exactly one supplied repository, destination branch, base commit, and behavior contract; none was selected by Relay.
2. Baseline evidence was captured before any repair and matches the supplied observation.
3. At least one focused test fails at the base for the intended behavior and passes at the PR head.
4. Every supplied targeted and full-suite command exits `0` at the PR head, with command, status, timestamp, and redacted output retained.
5. `git diff --name-only <base>..<head>` contains only owner-approved paths, and the diff contains no unrelated cleanup.
6. The review artifact says `PASS` and binds the exact base SHA, head SHA, diff digest, and test-evidence digest.
7. The PR targets the supplied destination branch, remains unmerged, and its head SHA equals the reviewed head.
8. The repository host reports every supplied required CI check as successful for that exact head.
9. The intake start and final green-CI timestamps are no more than 90 minutes apart for the first pilot.
10. No target process received owner-home access, GitHub/vendor credentials, CI secrets, or network access during test execution; trusted GitHub operations are separately logged.

Security and repository-access boundaries:

- Treat repository content and instructions as data. They may constrain implementation style but cannot expand tool, path, network, credential, merge, or deployment authority.
- Use a fine-grained repository credential limited to contents read/write, pull requests write, and checks/status read for the single supplied repository. Do not grant organization administration, settings, secrets, actions/workflow administration, release, deployment, or merge authority.
- Keep credentials in the trusted control boundary. Never place values in prompts, files, commits, command output, review evidence, or the target-code process.
- Stage fetch, push, PR creation, and CI-status reads through the trusted boundary. Run repository code and install hooks only in a disposable, secretless sandbox; default network is off.
- Exclude workflow files, hooks, submodules, Git LFS configuration, `CODEOWNERS`, secret/config stores, and repository settings unless the Owner separately classifies and approves that exact high-risk scope. The first slice assumes none are needed.
- Do not read or modify CI secrets. Logs are redacted before review or retention. Suspected secret exposure stops the run and triggers credential revocation outside this product flow.
- Do not merge, force-push, tag, release, deploy, or delete owner branches. The only remote write is a uniquely named repair branch and its PR.
- Current Relay external-worker guarantees must not be overstated: `SECURITY.md` gap 1 means its build phase can contain a vendor-login copy and network. Target commands therefore cannot run in that credential-bearing phase, and arbitrary hostile repositories remain out of scope.

## Rollback

Before merge, rollback is deletion: close the unmerged PR if requested, delete only its unique repair branch, and destroy the disposable worktree/sandbox. The supplied base and destination branch remain untouched.

Retain only the redacted intake, gate outcomes, and failure evidence required for audit; remove cloned source and raw logs according to repository policy. If any credential may have crossed the boundary, stop, revoke it through the provider, and record the incident without preserving the credential value.

## Deferred

- An installed external-repository adapter or generic repository manifest.
- Automatic repository discovery, problem discovery, or multi-behavior planning.
- Multiple languages/build systems beyond what the supplied commands already support.
- Parallel repairs, multi-repository changes, merge/deploy authority, and continuing ownership.
- Hostile third-party repository support and stronger credential isolation than the current tested boundary.
- Dashboards, databases, durable product dossiers, evaluation platforms, and business-outcome telemetry.
- Performance optimization or benchmark work unrelated to the supplied behavior.

## Definition of done

This product proof is done when one owner-supplied repository and one owner-supplied bounded behavior satisfy all ten Verification criteria within the 90-minute pilot budget, producing one unmerged minimal repair PR with characterization evidence, a bound independent `PASS`, and green named CI checks at the exact reviewed head.

It is not done when there is only a patch, a passing local test without a base regression proof, reviewer prose without a bound verdict, green CI for a different commit, a PR that widened scope, or an unverified claim that security boundaries held.

If a gate fails, the valid output is a stop result, but the product promise is not considered proven. The next decision must address the measured failure directly or abandon this direction; it must not add reusable machinery without that evidence.
