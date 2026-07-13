#!/usr/bin/env bash
# Standalone acceptance test for scripts/delegation_report.py.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
attempts="$tmp/attempts"
specs="$tmp/specs"
repo="$tmp/repo"
mkdir -p "$attempts" "$specs"

put_attempt() {
  local spec_id="$1" attempt="$2" merged="${3:-missing}"
  local dir="$attempts/$spec_id/$attempt"
  mkdir -p "$dir"
  printf '{"spec_id":"%s","attempt":%s}\n' "$spec_id" "$attempt" >"$dir/launch.json"
  if [ "$merged" != missing ]; then
    printf '{"spec_id":"%s","attempt":%s,"merged":%s}\n' \
      "$spec_id" "$attempt" "$merged" >"$dir/result.json"
  fi
}

printf 'id: SPEC-LOW\nrisk_class: low\n' >"$specs/SPEC-LOW.yaml"
printf 'id: SPEC-DEFAULT\nrisk_class: default\n' >"$specs/SPEC-DEFAULT.yaml"
printf 'id: SPEC-HIGH\nrisk_class: high\n' >"$specs/SPEC-HIGH.yaml"
printf 'id: SPEC-UNKNOWN\ntitle: no risk class\n' >"$specs/SPEC-UNKNOWN.yaml"
put_attempt SPEC-LOW 1 true
put_attempt SPEC-DEFAULT 1 false
put_attempt SPEC-HIGH 1
put_attempt SPEC-UNKNOWN 1 false

git init -q -b main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Delegation Report Test"
printf 'base\n' >"$repo/work.txt"
git -C "$repo" add work.txt
git -C "$repo" commit -qm base

git -C "$repo" switch -q -c codex/SPEC-LOW-1
printf 'codex\n' >>"$repo/work.txt"
git -C "$repo" commit -qam codex
git -C "$repo" switch -q main
git -C "$repo" merge -q --no-ff codex/SPEC-LOW-1 -m "Merge branch 'codex/SPEC-LOW-1'"

git -C "$repo" switch -q -c claude/control-plane
printf 'direct\n' >"$repo/control.txt"
git -C "$repo" add control.txt
git -C "$repo" commit -qm direct
git -C "$repo" switch -q main
git -C "$repo" merge -q --no-ff claude/control-plane -m "Merge branch 'claude/control-plane'"

snapshot() {
  find "$attempts" "$specs" "$repo" -printf '%y %m %s %T@ %p\n' | sort
}

before="$(snapshot)"
output="$(python3 scripts/delegation_report.py \
  --attempts-dir "$attempts" --specs-dir "$specs" --repo "$repo")"
after="$(snapshot)"
[ "$before" = "$after" ] || { echo "FAIL report modified its inputs" >&2; exit 1; }

REPORT="$output" python3 - <<'PY'
import json
import os

report = json.loads(os.environ["REPORT"])
expected_keys = {
    "codex_attempts_by_risk_class",
    "codex_attempts_total",
    "codex_merged_total",
    "claude_direct_merges",
    "codex_branch_merges",
    "window",
}
assert set(report) == expected_keys, report
assert report["codex_attempts_by_risk_class"] == {
    "low": 1, "default": 1, "high": 1, "unclassified": 1,
}, report
assert report["codex_attempts_total"] == 4, report
assert report["codex_merged_total"] == 1, report
assert report["codex_branch_merges"] == 1, report
assert report["claude_direct_merges"] == 1, report
assert report["window"]["current_branch"] == "main", report
assert "delegation_ratio" not in os.environ["REPORT"], report
PY

empty_repo="$tmp/empty-repo"
empty_attempts="$tmp/does-not-exist"
empty_specs="$tmp/empty-specs"
mkdir -p "$empty_specs"
git init -q -b main "$empty_repo"
git -C "$empty_repo" config user.email test@example.invalid
git -C "$empty_repo" config user.name "Delegation Report Test"
printf 'empty\n' >"$empty_repo/README"
git -C "$empty_repo" add README
git -C "$empty_repo" commit -qm initial

empty_output="$(python3 scripts/delegation_report.py \
  --attempts-dir "$empty_attempts" --specs-dir "$empty_specs" --repo "$empty_repo")"
REPORT="$empty_output" python3 - <<'PY'
import json
import os

report = json.loads(os.environ["REPORT"])
assert report["codex_attempts_by_risk_class"] == {
    "low": 0, "default": 0, "high": 0, "unclassified": 0,
}, report
for key in (
    "codex_attempts_total", "codex_merged_total",
    "claude_direct_merges", "codex_branch_merges",
):
    assert report[key] == 0, report
PY

echo "PASS delegation_report.sh"
