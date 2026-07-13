#!/usr/bin/env bash

squeeze() {
  printf '%s' "${1-}" | LC_ALL=C tr -s ' '
  printf '\n'
}
