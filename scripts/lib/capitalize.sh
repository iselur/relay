#!/usr/bin/env bash

capitalize() {
  local value=${1-}

  printf '%s' "${value:0:1}" | LC_ALL=C tr 'a-z' 'A-Z'
  printf '%s\n' "${value:1}"
}
