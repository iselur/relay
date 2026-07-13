#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/lower.sh

assert_lower() {
  local input=$1
  local expected=$2
  local actual

  actual=$(lower "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'lower %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_lower 'ABC' 'abc'
assert_lower 'AbC1' 'abc1'
assert_lower '' ''
