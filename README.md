# Relay

Relay is a reusable oversight approach for coding agents. It gives an agent a checked path from
a request to a pull request: a worker produces the change, the harness verifies it, and a
configured separate reviewer checks the exact diff before it moves forward.

The approach can be reused in any repository where coding agents need oversight. This repository
is a ready-to-run reference implementation for Linux, GitHub, and subscription CLIs; those
implementation choices belong to this reference, not to the approach itself.

## The workflow

`request` → `approved spec` → `worker build` → `harness checks` → `bound review` → `pull request`

The harness owns the authoritative commit, evidence, and release decision. Worker prose alone is
not proof: tests and checks must run against the exact candidate. Passing work targets
`ready-for-main`; promotion to `main` remains separately protected.

## What Relay provides

- Structured owner, orchestrator, worker, and reviewer roles.
- Exact-candidate scope, test, and review checks.
- A repeatable path from an approved request to a reviewable pull request.

Relay has been used across more than 500 production pull requests. Its worker/reviewer loop
repeatedly surfaced concrete issues and improvements before merge.

## See the system

[How Relay works](how-it-works.html) gives a visual overview of the flow and roles.

[BOOTSTRAP.md](BOOTSTRAP.md) is the setup path for making this repository yours. It walks through
the toolchain, GitHub, CLI access, worker isolation, and the first job.

[SECURITY.md](SECURITY.md) describes what repository tests prove, what depends on deployment
configuration, and the known gaps. Relay's guarantees are deliberately scoped.

[CLAUDE.md](CLAUDE.md) is the operating rulebook. [AGENTS.md](AGENTS.md) records the role
assignments and repository commands.

## Roles

The owner approves specs and protects the final promotion. The orchestrator coordinates the work
and applies the harness gates. The worker implements the approved spec. The bound reviewer checks
the exact candidate diff.

Worker and reviewer configuration lives in `scripts/models.json`; the orchestrator is whichever
supported CLI runs the process.

Relay keeps the implementation focused on evidence, scope, tests, and review so a repository can
use the same oversight pattern repeatedly.

MIT — see [LICENSE](LICENSE).
