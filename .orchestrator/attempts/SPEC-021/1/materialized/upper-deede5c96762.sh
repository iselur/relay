#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/upper.sh

assert_upper() {
  local input=$1
  local expected=$2
  local actual

  actual=$(upper "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'upper %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_upper 'abc' 'ABC'
assert_upper 'AbC1' 'ABC1'
assert_upper '' ''
