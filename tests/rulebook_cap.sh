#!/usr/bin/env bash
# R29: the 319-line rulebook was itself a root cause of degradation — rules accreted faster than
# product shipped. This caps it. Growing CLAUDE.md past the cap must be a deliberate, reviewed
# decision (edit this test in the same PR), never drift.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
lines=$(wc -l < CLAUDE.md)
if [ "$lines" -le 70 ]; then
  echo "  ok: CLAUDE.md is $lines lines (cap 70)"
else
  echo "  FAIL: CLAUDE.md is $lines lines — cap is 70. A rule must REPLACE something, not stack (R26/R29)."
  fails=1
fi

# The six working rules must actually be present — the cap must not be satisfied by deleting them.
for marker in "Intake:" "One workstream:" "Review cap:" "Communication:" "ONE brief" "Code discipline:"; do
  if grep -q "$marker" CLAUDE.md; then
    echo "  ok: rule present: $marker"
  else
    echo "  FAIL: working rule missing from CLAUDE.md: $marker"
    fails=1
  fi
done

[ "$fails" -eq 0 ] && echo "PASS rulebook_cap.sh" || echo "FAIL rulebook_cap.sh"
exit "$fails"
