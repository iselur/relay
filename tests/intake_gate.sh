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
