#!/usr/bin/env bash

repeat() {
  local value=${1-}
  local count=${2-0}
  local i

  for ((i = 0; i < count; i++)); do
    printf '%s' "$value"
  done
  printf '\n'
}
