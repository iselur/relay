#!/usr/bin/env bash
# R29: the 319-line rulebook was itself a root cause of degradation — rules accreted faster than
# product shipped. The line cap itself is enforced by prose_cap.sh; this test guards the content.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0

# The six working rules must actually be present — the cap must not be satisfied by deleting them.
for marker in "Intake:" "One workstream:" "Review cap:" "Communication:" "ONE brief" "Code discipline:"; do
  if grep -q "$marker" CLAUDE.md; then
    echo "  ok: rule present: $marker"
  else
    echo "  FAIL: working rule missing from CLAUDE.md: $marker"
    fails=1
  fi
done

if grep -Fq -- "Every high-risk dispatch needs an approval file from the owner, which the orchestrator never" CLAUDE.md; then
  echo "  FAIL: old high-risk approval wording remains in CLAUDE.md"
  fails=1
else
  echo "  ok: old high-risk approval wording absent"
fi

if grep -Fq -- "and stops wherever a gate stops it (HALT, a spent cap, any human-required approval)." CLAUDE.md; then
  echo "  FAIL: old autonomy-grant wording remains in CLAUDE.md"
  fails=1
else
  echo "  ok: old autonomy-grant wording absent"
fi

[ "$fails" -eq 0 ] && echo "PASS rulebook_cap.sh" || echo "FAIL rulebook_cap.sh"
exit "$fails"
