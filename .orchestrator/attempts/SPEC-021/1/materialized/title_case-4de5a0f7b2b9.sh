#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/title_case.sh

assert_title_case() {
  local input=$1
  local expected=$2
  local actual

  actual=$(title_case "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'title_case %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_title_case 'hello world' 'Hello World'
assert_title_case 'HELLO WORLD' 'Hello World'
assert_title_case 'a' 'A'
assert_title_case '' ''
assert_title_case 'a  b' 'A  B'
