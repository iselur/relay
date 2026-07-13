#!/usr/bin/env bash

upper() {
  printf '%s' "${1-}" | LC_ALL=C tr 'a-z' 'A-Z'
  printf '\n'
}
