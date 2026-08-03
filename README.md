# Relay

Relay is a reusable oversight approach for coding agents. It gives an agent a checked path from a
request to a pull request: a worker produces the change, the harness verifies it, and a configured
separate reviewer checks the exact diff before it moves forward.

Relay has been used across more than 500 production pull requests. In that use, the worker/reviewer
loop repeatedly surfaced concrete issues and improvements before merge. That is a record of repeated
production use, not a claim that Relay always outperforms direct model use.

The approach can be reused in any repository where coding agents need oversight. This repository is
a ready-to-run Linux/GitHub reference implementation using subscription-based CLIs. The approach
itself does not require a VPS, VM, or particular host.

## The compact flow

```text
request -> approved spec -> worker build -> harness checks -> bound review -> pull request
```

The harness owns the authoritative commit, evidence, and release decision. A worker's prose alone
is not proof. Passing work targets `ready-for-main`; promotion to `main` remains separately
protected.

The owner brings the request and approves the spec. The orchestrator coordinates the work, the
worker implements it, and the bound reviewer checks the exact candidate diff. The harness checks
scope, test execution, and review evidence before opening the pull request.

## Why use Relay

- Structured worker and reviewer roles.
- Exact-candidate scope, test, and review checks.
- Repeated use in production pull requests.

Relay is designed to make evidence visible at the point where work moves forward. It keeps the
roles and checks explicit without asking the reviewer to trust a worker's summary.

Relay's guarantees are deliberately scoped. [SECURITY.md](SECURITY.md) separates what repository
tests prove from deployment assumptions and known gaps.

## Learn more

- [How Relay works](how-it-works.html) explains the roles and flow visually.
- [BOOTSTRAP.md](BOOTSTRAP.md) is the setup path for this reference implementation.
- [SECURITY.md](SECURITY.md) is the source of truth for guarantees, assumptions, and gaps.
- [CLAUDE.md](CLAUDE.md) contains the operating rules.
- [AGENTS.md](AGENTS.md) contains repository conventions and commands.

Start with the setup path when using this repository. Adapt the oversight approach to the repository,
agent tools, and release controls that your team already uses.

MIT — see [LICENSE](LICENSE).
