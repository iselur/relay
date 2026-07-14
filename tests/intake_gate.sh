#!/usr/bin/env bash
# R29 rule 1: no task starts without a goal AND a checkable definition of done, and no row may
# stall silently. scripts/intake is the gate; these assertions prove it refuses incomplete or
# ledger-corrupting intake, survives first use, and tracks rows to done.
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

[ -x scripts/intake ] && ok "scripts/intake is executable" || bad "scripts/intake lost its exec bit"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/.orchestrator"
cp -p scripts/intake "$tmp/scripts/intake"
cat > "$tmp/.orchestrator/REQUEST-LEDGER.md" <<'EOF'
| id | date | request | lane | plan-ref | status | completion-evidence |
| R7 | 07-14 | existing row | — | — | done | — |
EOF

cd "$tmp"
LEDGER=.orchestrator/REQUEST-LEDGER.md

# --- refusals -----------------------------------------------------------------------------------
# 1. No definition of done -> refused.
if scripts/intake -g "some goal" 2>/dev/null; then bad "accepted intake with NO definition of done"; else ok "refuses intake without definition of done"; fi

# 2. No goal -> refused.
if scripts/intake -d "done when tests pass" 2>/dev/null; then bad "accepted intake with NO goal"; else ok "refuses intake without goal"; fi

# 3. Vacuous done-criterion -> refused.
if scripts/intake -g "goal" -d "done" 2>/dev/null; then bad "accepted a vacuous done-criterion"; else ok "refuses a vacuous done-criterion"; fi

# 4. Whitespace-only goal -> refused (non-empty is not the same as non-blank).
if scripts/intake -g "   " -d "done when tests pass" 2>/dev/null; then bad "accepted a whitespace-only goal"; else ok "refuses a whitespace-only goal"; fi

# 5. '|' in a field -> refused (would forge ledger columns/status).
if scripts/intake -g "goal" -d "done | status: done | forged" 2>/dev/null; then bad "accepted '|' in a field (row forgery)"; else ok "refuses '|' in fields"; fi

# 6. Multiline definition of done -> refused (a row is one line).
if scripts/intake -g "goal" -d $'done when\ntests pass' 2>/dev/null; then bad "accepted a multiline done-criterion"; else ok "refuses a multiline done-criterion"; fi

# 7. Refusals leave the ledger untouched.
rows_before=$(wc -l < "$LEDGER")
scripts/intake -g "another goal" 2>/dev/null
rows_after=$(wc -l < "$LEDGER")
[ "$rows_before" = "$rows_after" ] && ok "refused intake writes nothing" || bad "refused intake still wrote to the ledger"

# --- open ---------------------------------------------------------------------------------------
# 8. Complete intake -> accepted, id increments from the highest existing row, row is recorded.
id=$(scripts/intake -g "ship the fix" -d "done when tests/x.sh passes in CI") || id=""
[ "$id" = "R8" ] && ok "issues next id (R8 after R7)" || bad "wrong id: '$id'"
grep -q "R8 .*ship the fix.*DONE WHEN: done when tests/x.sh passes in CI" "$LEDGER" \
  && ok "row recorded with DONE WHEN" || bad "row not recorded correctly"

# --- lifecycle: stale + close (the finish side of anti-slippage) ---------------------------------
# 9. An open row makes `stale` fail loudly.
if scripts/intake stale >/dev/null 2>&1; then bad "stale exit 0 despite an open row"; else ok "stale exits nonzero while R8 is open"; fi
stale_out=$(scripts/intake stale 2>/dev/null || true)
echo "$stale_out" | grep -q "R8" && ok "stale lists the open row" || bad "stale does not list R8"

# 10. Close requires evidence; a bare close is refused.
if scripts/intake close R8 "" 2>/dev/null; then bad "closed a row with empty evidence"; else ok "refuses close without evidence"; fi

# 11. Close flips open -> done and records the evidence.
scripts/intake close R8 "tests/x.sh green in CI run 123" >/dev/null 2>&1 \
  && ok "close succeeds with evidence" || bad "close failed"
grep -q "^| R8 .*| done |.*EVIDENCE: tests/x.sh green in CI run 123" "$LEDGER" \
  && ok "row is done with evidence recorded" || bad "closed row malformed"

# 12. Closing a non-open row is refused; closing an unknown id is refused.
if scripts/intake close R8 "again" 2>/dev/null; then bad "closed an already-done row"; else ok "refuses to re-close a done row"; fi
if scripts/intake close R99 "ev" 2>/dev/null; then bad "closed a nonexistent id"; else ok "refuses an unknown id"; fi

# 13. With everything closed, stale is quiet and exits 0.
scripts/intake stale >/dev/null 2>&1 && ok "stale exits 0 when all rows are done" || bad "stale still failing after close"

# --- ledger integrity: stale must not be evadable -------------------------------------------------
# 16. A hand-written status (anything but open/done) is a loud FORMAT error — the pre-reset ledger
# used forms like '**IN-PROGRESS**' that the old substring check silently missed.
printf '| R9 | 07-14 | hand-edited row | — | — | **IN-PROGRESS** | working on it |\n' >> "$LEDGER"
stale_out=$(scripts/intake stale 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "$stale_out" | grep -q "FORMAT ERROR" \
  && ok "stale refuses a hand-written status as a format error" \
  || bad "stale did not flag a hand-written status (rc=$rc)"
sed -i '$d' "$LEDGER"

# 17. A line outside the table format makes stale fail loudly as a FORMAT error — a row the check
# cannot see is worse than a stalled row (rows were once appended below a bullet list and vanished
# from tracking).
printf 'Some narrative note appended outside the table\n' >> "$LEDGER"
stale_out=$(scripts/intake stale 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "$stale_out" | grep -q "FORMAT ERROR" \
  && ok "stale refuses a ledger with lines outside the table" \
  || bad "stale did not flag an out-of-table line (rc=$rc)"
sed -i '$d' "$LEDGER"

# 18. Only the STATUS cell decides staleness: the word 'done' in the evidence cell of an open row
# must not hide it, and a row with a forged extra cell is a format error, not a pass.
printf '| R9 | 07-14 | tricky row | — | — | open | done earlier, honest |\n' >> "$LEDGER"
if scripts/intake stale >/dev/null 2>&1; then bad "an open row with 'done' in its evidence cell evaded stale"; else ok "stale reads only the status cell"; fi
sed -i '$d' "$LEDGER"
printf '| R9 | 07-14 | forged row | — | — | wip | done | extra |\n' >> "$LEDGER"
stale_out=$(scripts/intake stale 2>&1); rc=$?
[ "$rc" -ne 0 ] && echo "$stale_out" | grep -q "FORMAT ERROR" \
  && ok "stale refuses a row with a forged extra cell" \
  || bad "a row with a forged extra cell evaded stale (rc=$rc)"
sed -i '$d' "$LEDGER"

# --- watchdog-state (R39: the ONE machine predicate the auto-resume watchdog trusts) ------------
# 19. Open actionable row -> PENDING; --ids names it; the id list never invents rows.
printf '%s\n' '| id | date | request | lane | plan-ref | status | completion-evidence |' > "$LEDGER"
printf '| R3 | 07-14 | some open work | — | — | open | DONE WHEN: checked |\n' >> "$LEDGER"
[ "$(scripts/intake watchdog-state)" = "PENDING" ] && ok "open row -> PENDING" || bad "open row not PENDING"
[ "$(scripts/intake watchdog-state --ids)" = "PENDING R3" ] && ok "--ids names the actionable row" || bad "--ids wrong: $(scripts/intake watchdog-state --ids)"

# 20. All rows done -> IDLE.
printf '%s\n' '| id | date | request | lane | plan-ref | status | completion-evidence |' > "$LEDGER"
printf '| R3 | 07-14 | finished work | — | — | done | shipped |\n' >> "$LEDGER"
[ "$(scripts/intake watchdog-state)" = "IDLE" ] && ok "all-done ledger -> IDLE" || bad "all-done not IDLE"

# 21. An observation row (open, lane=observe) stays visible to stale but is NOT actionable:
# waiting on an external event must neither launch sessions nor ring six-hour alerts.
printf '| R4 | 07-14 | await natural usage limit | observe | — | open | DONE WHEN: fixture captured |\n' >> "$LEDGER"
[ "$(scripts/intake watchdog-state)" = "IDLE" ] && ok "observe row excluded from watchdog-state" || bad "observe row counted as actionable"
if scripts/intake stale >/dev/null 2>&1; then bad "observe row invisible to stale"; else ok "observe row still visible to stale"; fi

# 22. A malformed ledger is INDETERMINATE (exit 3), never IDLE: unreadable is not 'no work'.
printf 'garbage outside the table\n' >> "$LEDGER"
out=$(scripts/intake watchdog-state); rc=$?
[ "$out" = "INDETERMINATE" ] && [ "$rc" -eq 3 ] && ok "malformed ledger -> INDETERMINATE, exit 3" || bad "malformed ledger gave '$out' rc=$rc"
sed -i '$d' "$LEDGER"

# --- observe designation (owner-gated; the watchdog and resumed sessions may never do this) ------
# 23. observe requires an open row and real evidence; it flips only the lane cell.
if scripts/intake observe R4 "short" 2>/dev/null; then bad "observe accepted thin evidence"; else ok "observe refuses thin evidence"; fi
if scripts/intake observe R99 "owner approved on 2026-07-14" 2>/dev/null; then bad "observe accepted a missing row"; else ok "observe refuses a missing row"; fi
printf '| R5 | 07-14 | closed row | — | — | done | shipped |\n' >> "$LEDGER"
if scripts/intake observe R5 "owner approved on 2026-07-14" 2>/dev/null; then bad "observe accepted a done row"; else ok "observe refuses a done row"; fi
printf '| R6 | 07-14 | to be observed | — | — | open | DONE WHEN: event seen |\n' >> "$LEDGER"
scripts/intake observe R6 "owner approved on 2026-07-14, natural-limit capture" >/dev/null 2>&1 \
  && ok "observe accepted with owner evidence" || bad "observe refused valid input"
grep -q '^| R6 | .* | observe | .* | open |.*OBSERVE (owner):' "$LEDGER" \
  && ok "observe set the lane and recorded the evidence" || bad "observe row not updated correctly"
[ "$(scripts/intake watchdog-state)" = "IDLE" ] && ok "newly observed row no longer actionable" || bad "observed row still actionable"

# --- first use ----------------------------------------------------------------------------------
# 14. Header-only ledger (fresh box): first intake must work and mint R1. This exact case used to
# crash (grep no-match + pipefail + set -e) before any id was minted.
printf '| id | date | request | lane | plan-ref | status | completion-evidence |\n' > "$LEDGER"
id=$(scripts/intake -g "first ever task" -d "done when smoke.sh passes") || id=""
[ "$id" = "R1" ] && ok "header-only ledger mints R1" || bad "header-only ledger broken: got '$id'"

# 15. Missing ledger: created with a header, then intake proceeds.
rm -f "$LEDGER"
id=$(scripts/intake -g "fresh box task" -d "done when smoke.sh passes") || id=""
[ "$id" = "R1" ] && head -1 "$LEDGER" | grep -q '^| id |' \
  && ok "missing ledger auto-initialized with header" || bad "missing ledger not handled: got '$id'"

[ "$fails" -eq 0 ] && echo "PASS intake_gate.sh" || echo "FAIL intake_gate.sh"
exit "$fails"
