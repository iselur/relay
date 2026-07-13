#!/usr/bin/env bash

slugify() {
  printf '%s' "${1-}" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//'
  printf '\n'
}
