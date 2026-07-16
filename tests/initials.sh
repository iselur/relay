#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/initials.sh

assert_initials() {
  local input=$1
  local expected=$2
  local actual

  actual=$(initials "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'initials %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_initials 'hello brave world' 'HBW'
assert_initials 'already Upper case' 'AUC'
assert_initials 'single' 'S'
assert_initials '' ''
assert_initials 'a  b' 'AB'
