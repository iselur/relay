#!/usr/bin/env bash
# Guards the CI contract itself.
#
# The branch ruleset on `main` and `integration` requires a status check whose
# context is exactly `ci`. GitHub derives that context from the job name, so a
# rename here would not fail CI — it would make CI silently stop reporting under
# the name the ruleset waits for, and every PR would block forever with no error
# to read. That failure mode is invisible and expensive, so it gets a test.
set -euo pipefail
cd "$(dirname "$0")/.."

wf=".github/workflows/ci.yml"

[ -f "$wf" ] || { echo "missing $wf"; exit 1; }

grep -qE '^  ci:$'        "$wf" || { echo "job key must be exactly 'ci' in $wf"; exit 1; }
grep -qE '^    name: ci$' "$wf" || { echo "job name must be exactly 'ci' in $wf"; exit 1; }
grep -qE '^\s*strategy:'  "$wf" && { echo "a matrix would change the check context away from 'ci'"; exit 1; }

echo "ci status-check contract intact"
