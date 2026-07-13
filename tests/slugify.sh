#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/slugify.sh

assert_slug() {
  local input=$1
  local expected=$2
  local actual

  actual=$(slugify "$input")
  if [[ $actual != "$expected" ]]; then
    printf 'slugify %q: expected %q, got %q\n' \
      "$input" "$expected" "$actual" >&2
    return 1
  fi
}

assert_slug 'Hello, World!' 'hello-world'
assert_slug '  a__b ' 'a-b'
assert_slug '' ''
