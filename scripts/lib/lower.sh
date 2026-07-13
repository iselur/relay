#!/usr/bin/env bash

lower() {
  printf '%s\n' "${1-}" | LC_ALL=C tr 'A-Z' 'a-z'
}
