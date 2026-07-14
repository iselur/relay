#!/usr/bin/env bash
# The bloat guard. This repo once held ~39,000 lines of process prose against ~4,000 lines of
# code, and the operator stopped understanding his own system. Standing prose is now allowlisted
# and capped; git history keeps everything deleted. Growing past a cap must be a deliberate,
# reviewed edit to this test — never drift.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v git >/dev/null 2>&1 || { echo "SKIP prose_cap.sh: git absent"; exit 77; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "SKIP prose_cap.sh: not a git checkout"; exit 77; }

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

# Collect the file list up front: an empty list is itself a failure, never a vacuous pass, and
# any Markdown extension (any case) counts — .md-only matching was an evasion route.
mapfile -t md_files < <(git ls-files | grep -iE '\.(md|markdown|mdown|mkd)$')
if [ "${#md_files[@]}" -eq 0 ]; then
  echo "  FAIL: found no tracked markdown at all — the file scan is broken, not the repo clean"
  echo "FAIL prose_cap.sh"
  exit 1
fi

# 1. Every tracked markdown file must be on the allowlist with a line cap. A new standing document
#    is a reviewed decision: add it here AND give it a cap, in the same PR.
declare -A cap=(
  [CLAUDE.md]=80
  [AGENTS.md]=45
  [README.md]=100
  [BOOTSTRAP.md]=80
  [SECURITY.md]=100
  [DECISIONS.md]=60
  [.orchestrator/BACKLOG.md]=40
  [.orchestrator/VISION.md]=40
)
total_lines=0
total_bytes=0
for f in "${md_files[@]}"; do
  lines=$(awk 'END { print NR }' < "$f")   # NR counts a final unterminated line; wc -l does not
  bytes=$(wc -c < "$f")
  case "$lines" in
    ''|*[!0-9]*) bad "could not count lines in $f — a cap that cannot count must not pass"; continue ;;
  esac
  total_lines=$((total_lines + lines))
  total_bytes=$((total_bytes + bytes))
  if [ -z "${cap[$f]:-}" ]; then
    bad "tracked markdown outside the allowlist: $f — standing prose is allowlisted; put content in an existing file or add it here as a reviewed decision"
  elif [ "$lines" -gt "${cap[$f]}" ]; then
    bad "$f is $lines lines — cap is ${cap[$f]}. Delete before you add."
  else
    ok "$f: $lines/${cap[$f]} lines"
  fi
done

# 2. Totals: 600 lines AND 60,000 bytes — the byte cap stops one-line walls of text that a line
#    count cannot see. A zero total means the counting broke (this exact check once passed
#    vacuously with "0/600" because awk was invoked wrong) — zero is a failure, not a clean repo.
[ "$total_lines" -gt 0 ] || bad "total tracked markdown counted as 0 lines — the count is broken, not the repo empty"
[ "$total_lines" -le 600 ]   && ok "total tracked markdown: $total_lines/600 lines" \
  || bad "total tracked markdown is $total_lines lines — cap is 600. Delete before you add."
[ "$total_bytes" -le 60000 ] && ok "total tracked markdown: $total_bytes/60000 bytes" \
  || bad "total tracked markdown is $total_bytes bytes — cap is 60000. Delete before you add."

# 3. The prose graveyards stay empty: plans and review rounds are untracked working files;
#    a decision that still binds gets one line in DECISIONS.md.
if git ls-files -- .orchestrator/decisions .orchestrator/plans .orchestrator/reviews | grep -q .; then
  bad "tracked files under .orchestrator/{decisions,plans,reviews} — these are transient; conclusions go to DECISIONS.md, arguments to the PR"
else
  ok "no tracked files under .orchestrator/{decisions,plans,reviews}"
fi

# 4. Backlog item #1 must carry a parseable 'product:' line naming something other than this repo
#    (the one measured failure mode of this setup was pointing itself at itself). Loose keyword
#    matching was evadable; a dedicated field is not.
item1=$(awk '/^1\./ { grab = 1 } /^2\./ { grab = 0 } grab' .orchestrator/BACKLOG.md 2>/dev/null)
product=$(printf '%s\n' "$item1" | sed -n 's/^[[:space:]]*product:[[:space:]]*//p' | head -1)
if [ -z "$product" ]; then
  bad "backlog item #1 has no 'product:' line — item #1 must name a real product outside this repo (CLAUDE.md rule 2)"
elif printf '%s' "$product" | grep -qiE '^(this repo|orchestrator)$'; then
  bad "backlog item #1 product is '$product' — improving this system is never item #1"
else
  ok "backlog item #1 product: $product"
fi

[ "$fails" -eq 0 ] && echo "PASS prose_cap.sh" || echo "FAIL prose_cap.sh"
exit "$fails"
