Usage-limit framing fixtures (brief PLAN-002, behavior c; activation gated on the follow-up row).

Each *.sed file here is an approved framing: a `sed -nE` script that prints a UTC reset epoch
(unix seconds) when — and only when — the raw, ANSI-stripped claude CLI usage-limit framing
matches. Model or tool text that merely LOOKS like a limit message must not match; ship every
fixture with negative cases in tests/auto_resume_watchdog.sh proving it cannot be spoofed.

This directory deliberately ships EMPTY of fixtures. The first real fixture comes from a
sanitized capture of a naturally occurring limit on this box (observation follow-up row), is
reviewed like any trust-critical change, and only then may USAGE_RETRY_MODE=active be approved
by the owner. Until then the classifier recognizes nothing and the watchdog never sends
post-reset input.
