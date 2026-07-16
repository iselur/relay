#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/trim.sh

assert_trim() {
  local input=$1
  local expected=$2
  local actual

  actual=$(trim "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'trim %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_trim '  hi  ' 'hi'
assert_trim 'a  b' 'a  b'
assert_trim '' ''
