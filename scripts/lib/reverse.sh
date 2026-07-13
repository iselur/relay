#!/usr/bin/env bash

reverse() {
  local value=${1-}
  local i

  for ((i = ${#value} - 1; i >= 0; i--)); do
    printf '%s' "${value:i:1}"
  done
  printf '\n'
}
