#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/squeeze.sh

assert_squeeze() {
  local input=$1
  local expected=$2
  local actual

  actual=$(squeeze "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'squeeze %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_squeeze 'a   b  c' 'a b c'
assert_squeeze '' ''
