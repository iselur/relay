#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/reverse.sh

assert_reverse() {
  local input=$1
  local expected=$2
  local actual

  actual=$(reverse "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'reverse %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_reverse 'abc' 'cba'
assert_reverse '' ''
assert_reverse 'a' 'a'
