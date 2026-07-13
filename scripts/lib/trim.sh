#!/usr/bin/env bash

trim() {
  local value=${1-}
  local whitespace=$' \t\r\n\v\f'

  value=${value#"${value%%[!$whitespace]*}"}
  value=${value%"${value##*[!$whitespace]}"}
  printf '%s\n' "$value"
}
