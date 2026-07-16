#!/usr/bin/env bash

title_case() {
  local value=${1-}
  local result=
  local at_word_start=1
  local char
  local i

  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    if [[ $char == [[:space:]] ]]; then
      result+=$char
      at_word_start=1
    elif ((at_word_start)); then
      result+=$(printf '%s' "$char" | LC_ALL=C tr 'a-z' 'A-Z')
      at_word_start=0
    else
      result+=$(printf '%s' "$char" | LC_ALL=C tr 'A-Z' 'a-z')
    fi
  done

  printf '%s\n' "$result"
}
