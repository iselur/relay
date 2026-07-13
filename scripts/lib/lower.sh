#!/usr/bin/env bash

lower() {
  printf '%s' "${1-}" | LC_ALL=C tr 'A-Z' 'a-z'
  printf '\n'
}
