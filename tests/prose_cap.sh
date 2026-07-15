#!/usr/bin/env bash
# The bloat guard. This repo once held ~39,000 lines of process prose against ~4,000 lines of
# code, and the operator stopped understanding his own system. Standing prose is now allowlisted
# and capped; git history keeps everything deleted. Growing past a cap must be a deliberate,
# reviewed edit to this test — never drift.
set -uo pipefail
INSTALLED_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ROOT="${ORCH_TEST_TARGET_ROOT:-$INSTALLED_ROOT}"
TARGET_COMMIT="${ORCH_TEST_TARGET_COMMIT:-}"
cd "$TARGET_ROOT"

command -v git >/dev/null 2>&1 || { echo "SKIP prose_cap.sh: git absent"; exit 77; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "SKIP prose_cap.sh: not a git checkout"; exit 77; }

fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=1; }

# Collect the file list up front. In candidate-read mode, materialize exact Git blobs into a
# private temporary directory; the installed policy then treats those bytes only as data.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
SNAP=""
declare -a md_files=()
declare -a all_paths=()   # every tracked path (for the graveyard check — not markdown-only)
if [ -n "$TARGET_COMMIT" ]; then
  [[ "$TARGET_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL prose_cap.sh: target commit is not a full SHA"; exit 1; }
  resolved=$(GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 git -C "$TARGET_ROOT" \
    -c core.hooksPath=/dev/null -c core.attributesFile=/dev/null rev-parse --verify "$TARGET_COMMIT^{commit}" 2>/dev/null)
  [ "$resolved" = "$TARGET_COMMIT" ] || { echo "FAIL prose_cap.sh: target commit cannot be resolved exactly"; exit 1; }
  SNAP="$tmp/snapshot"; mkdir -p "$SNAP"
  records="$tmp/tree"
  GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 git -C "$TARGET_ROOT" \
    -c core.hooksPath=/dev/null -c core.attributesFile=/dev/null \
    ls-tree -r -z --full-tree "$TARGET_COMMIT" > "$records" || exit 1
  while IFS= read -r -d '' rec; do
    meta=${rec%%$'\t'*}; path=${rec#*$'\t'}
    read -r mode type oid <<<"$meta"
    if [ "$path" = "$rec" ] || [ "$type" != blob ] || [[ "$path" = /* ]] \
       || [[ "$path" =~ [[:cntrl:]] ]] || [[ "/$path/" == *"/../"* ]] \
       || [[ "/$path/" == *"/./"* ]] || [[ "$path" == *"//"* ]] \
       || { [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; }; then
      echo "FAIL prose_cap.sh: unsafe or malformed candidate tree entry"; exit 1
    fi
    all_paths+=("$path")   # graveyard check needs ALL paths, not just markdown
    if [[ "$path" =~ \.[mM][dD]$|\.[mM][aA][rR][kK][dD][oO][wW][nN]$|\.[mM][dD][oO][wW][nN]$|\.[mM][kK][dD]$ ]]; then
      md_files+=("$path")
      mkdir -p "$SNAP/$(dirname -- "$path")"
      GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 git -C "$TARGET_ROOT" \
        -c core.hooksPath=/dev/null cat-file blob "$oid" > "$SNAP/$path" || exit 1
    fi
  done < "$records"
else
  mapfile -t md_files < <(git ls-files | grep -iE '\.(md|markdown|mdown|mkd)$')
  mapfile -t all_paths < <(git ls-files)
fi
if [ "${#md_files[@]}" -eq 0 ]; then
  echo "  FAIL: found no tracked markdown at all — the file scan is broken, not the repo clean"
  echo "FAIL prose_cap.sh"
  exit 1
fi

# 1. Every tracked markdown file must be on the allowlist with a line cap. A new standing document
#    is a reviewed decision: add it here AND give it a cap, in the same PR.
declare -A cap=(
  [CLAUDE.md]=65  # lowered from 80 with the 2026-07-15 lean rewrite: lock the gains in
  [AGENTS.md]=60   # raised from 45 with the role→vendor table: the rulebook now speaks in roles,
                   # and this is the one place a model name may appear, so swapping a vendor is an
                   # edit here and nowhere else.
  [README.md]=100
  [BOOTSTRAP.md]=80
  [SECURITY.md]=110
  [.orchestrator/BACKLOG.md]=45
)
total_lines=0
total_bytes=0
for f in "${md_files[@]}"; do
  source_file="$f"; [ -z "$SNAP" ] || source_file="$SNAP/$f"
  lines=$(awk 'END { print NR }' < "$source_file")   # NR counts a final unterminated line
  bytes=$(wc -c < "$source_file")
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

# 2. Totals: 500 lines AND 60,000 bytes — the byte cap stops one-line walls of text that a line
#    count cannot see. A zero total means the counting broke (this exact check once passed
#    vacuously with "0/600" because awk was invoked wrong) — zero is a failure, not a clean repo.
[ "$total_lines" -gt 0 ] || bad "total tracked markdown counted as 0 lines — the count is broken, not the repo empty"
[ "$total_lines" -le 500 ]   && ok "total tracked markdown: $total_lines/500 lines" \
  || bad "total tracked markdown is $total_lines lines — cap is 500. Delete before you add."
[ "$total_bytes" -le 60000 ] && ok "total tracked markdown: $total_bytes/60000 bytes" \
  || bad "total tracked markdown is $total_bytes bytes — cap is 60000. Delete before you add."

# 3. The prose graveyards stay empty: plans and review rounds are untracked working files. A
#    decision that still binds is a RULE (CLAUDE.md); one that no longer binds is history (git).
graveyard=0
for f in "${all_paths[@]}"; do
  case "$f" in .orchestrator/decisions/*|.orchestrator/plans/*|.orchestrator/reviews/*) graveyard=1 ;; esac
done
if [ "$graveyard" -eq 1 ]; then
  bad "tracked files under .orchestrator/{decisions,plans,reviews} — these are transient; a binding decision becomes a rule in CLAUDE.md, the argument stays in the PR"
else
  ok "no tracked files under .orchestrator/{decisions,plans,reviews}"
fi

# 4. The backlog must ALWAYS carry at least one real product outside this repo. The owner relaxed
#    the old "item #1 must be the product" rule on 2026-07-14 (self-work may be scheduled first),
#    but not the guard behind it: the one measured failure of this setup was pointing itself at
#    itself with no outside finish line. The field must sit INSIDE a numbered backlog item (a
#    stray line anywhere in the file is not a queued item), and it must name something — a
#    placeholder or a reference to this repo is not a product. This function is the whole check,
#    so the negative fixtures below can exercise it directly.
backlog_product() { # $1 = backlog file; echoes the product name, or nothing if there is none
  awk '
    /^[0-9]+\./           { in_item = 1 }                    # a numbered item opens the block
    /^[^ \t0-9]/          { if (!/^[0-9]+\./) in_item = 0 }  # any other left-margin line closes it
    in_item && /^[ \t]*product:[ \t]*/ {
      sub(/^[ \t]*product:[ \t]*/, ""); sub(/[ \t]+$/, "")
      if ($0 == "") next
      lower = tolower($0)
      if (lower ~ /^(this repo|this repository|orchestrator|the orchestrator|tbd|todo|tba|none|n\/a|-+)$/) next
      print; exit
    }
  ' "$1"
}
backlog=.orchestrator/BACKLOG.md; [ -z "$SNAP" ] || backlog="$SNAP/.orchestrator/BACKLOG.md"
product=$(backlog_product "$backlog" 2>/dev/null)
if [ -z "$product" ]; then
  bad "no numbered backlog item carries a 'product:' line naming a real product outside this repo — the backlog may never be without one (CLAUDE.md rule 2)"
else
  ok "backlog carries a real product: $product"
fi

# 4b. The guard above must actually discriminate — this repo once shipped a cap test that passed
#     vacuously. Each fixture is a way the check was evaded before it was tightened.
fixture="$tmp/fixture"
for bad_case in "product: TBD" "product: this repository" "product: orchestrator" "product: -"; do
  printf '1. **Item**\n   %s\n' "$bad_case" > "$fixture"
  [ -z "$(backlog_product "$fixture")" ] \
    && ok "rejected placeholder/self-reference: $bad_case" \
    || bad "accepted a non-product: $bad_case"
done
printf 'product: stray line outside every item\n\n1. **Item**\n   no product field\n' > "$fixture"
[ -z "$(backlog_product "$fixture")" ] \
  && ok "rejected a 'product:' line outside every numbered item" \
  || bad "accepted a 'product:' line that is not inside a backlog item"
printf '1. **Self-work first**\n   product: orchestrator\n2. **Real thing**\n   product: reading-coach app\n' > "$fixture"
[ "$(backlog_product "$fixture")" = "reading-coach app" ] \
  && ok "skips a self-reference and finds the real product further down the list" \
  || bad "a self-referencing item hid the real product below it"

[ "$fails" -eq 0 ] && echo "PASS prose_cap.sh" || echo "FAIL prose_cap.sh"
exit "$fails"
