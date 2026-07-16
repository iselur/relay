#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/repeat.sh

assert_repeat() {
  local value=$1
  local count=$2
  local expected=$3
  local actual

  actual=$(repeat "$value" "$count")
  if [[ $actual != "$expected" ]]; then
    printf 'repeat %q %q: expected %q, got %q\n' \
      "$value" "$count" "$expected" "$actual" >&2
    return 1
  fi
}

assert_repeat 'ab' 3 'ababab'
assert_repeat 'x' 0 ''
assert_repeat 'z' 1 'z'
