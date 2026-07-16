#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/capitalize.sh

assert_capitalize() {
  local input=$1
  local expected=$2
  local actual

  actual=$(capitalize "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'capitalize %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_capitalize 'hello world' 'Hello world'
assert_capitalize '' ''
assert_capitalize '9lives' '9lives'
