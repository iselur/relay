#!/usr/bin/env bash
# Plain-language guard (CLAUDE.md rule 4). The pre-reset repo coined so much private vocabulary
# ("oracle", "baton", decision codenames cited like law) that the operator stopped understanding
# his own system. Standing prose must be readable by a newcomer: banned terms fail CI.
set -uo pipefail
INSTALLED_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ROOT="${ORCH_TEST_TARGET_ROOT:-$INSTALLED_ROOT}"
TARGET_COMMIT="${ORCH_TEST_TARGET_COMMIT:-}"
cd "$TARGET_ROOT"

command -v git >/dev/null 2>&1 || { echo "SKIP plain_language.sh: git absent"; exit 77; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "SKIP plain_language.sh: not a git checkout"; exit 77; }

LIST="$INSTALLED_ROOT/tests/banned-terms.txt"
[ -f "$LIST" ] || { echo "FAIL plain_language.sh: $LIST missing"; exit 1; }

fails=0
patterns=$(grep -v '^#' -- "$LIST" | grep -v '^[[:space:]]*$')
[ -n "$patterns" ] || { echo "FAIL plain_language.sh: $LIST has no patterns — the sweep would be vacuous"; exit 1; }

# A malformed pattern must fail the test, never silently disable the sweep: grep exits 2 on a bad
# regex, and only 0 (match) / 1 (no match) are acceptable outcomes below.
printf '%s\n' "$patterns" | grep -qiEf /dev/stdin -- /dev/null
[ $? -le 1 ] || { echo "FAIL plain_language.sh: invalid regex in $LIST"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
declare -a md_files=() md_oids=()
if [ -n "$TARGET_COMMIT" ]; then
  [[ "$TARGET_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "FAIL plain_language.sh: target commit is not a full SHA"; exit 1; }
  resolved=$(GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 git -C "$TARGET_ROOT" \
    -c core.hooksPath=/dev/null -c core.attributesFile=/dev/null rev-parse --verify "$TARGET_COMMIT^{commit}" 2>/dev/null)
  [ "$resolved" = "$TARGET_COMMIT" ] || { echo "FAIL plain_language.sh: target commit cannot be resolved exactly"; exit 1; }
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
      echo "FAIL plain_language.sh: unsafe or malformed candidate tree entry"; exit 1
    fi
    if [[ "$path" =~ \.[mM][dD]$|\.[mM][aA][rR][kK][dD][oO][wW][nN]$|\.[mM][dD][oO][wW][nN]$|\.[mM][kK][dD]$ ]]; then
      md_files+=("$path"); md_oids+=("$oid")
    fi
  done < "$records"
else
  mapfile -t md_files < <(git ls-files | grep -iE '\.(md|markdown|mdown|mkd)$')
fi
[ "${#md_files[@]}" -gt 0 ] || { echo "FAIL plain_language.sh: no tracked markdown found — scan broken"; exit 1; }

for i in "${!md_files[@]}"; do
  f=${md_files[$i]}; scan="$f"
  if [ -n "$TARGET_COMMIT" ]; then
    scan="$tmp/blob-$i"
    GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1 git -C "$TARGET_ROOT" \
      -c core.hooksPath=/dev/null cat-file blob "${md_oids[$i]}" > "$scan" || {
        echo "  FAIL: cannot read exact candidate blob for $f"; fails=1; continue; }
  fi
  hits=$(printf '%s\n' "$patterns" | grep -inEf /dev/stdin -- "$scan"); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  FAIL: banned term in $f (plain words or a name of real code, please):"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fails=1
  elif [ "$rc" -ge 2 ]; then
    echo "  FAIL: grep error scanning $f (exit $rc) — a check that cannot run must not pass"
    fails=1
  fi
  # "SOL" is case-sensitive: the lowercase model id gpt-5.6-sol in config lines is fine; the
  # uppercase character name that colonized the old prose is not.
  hits=$(grep -nE -- '\bSOL\b' "$scan"); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  FAIL: 'SOL' used as a name in $f — say 'Codex'; the model id belongs only in config/scripts:"
    printf '%s\n' "$hits" | sed 's/^/    /'
    fails=1
  elif [ "$rc" -ge 2 ]; then
    echo "  FAIL: grep error scanning $f (exit $rc) — a check that cannot run must not pass"
    fails=1
  fi
done

[ "$fails" -eq 0 ] && echo "PASS plain_language.sh" || echo "FAIL plain_language.sh"
exit "$fails"
