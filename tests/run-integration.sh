#!/usr/bin/env bash
# run-integration.sh — Tier 1: mock-based integration tests. No network, no key.
# Usage: bash tests/run-integration.sh [extra node --test args]
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
# Guard: node --test exits 0 on an empty glob, which would let a broken
# checkout (or a bad rename) pass silently. Fail loudly if no test files match.
found=0
for f in "$DIR"/integration/*.test.*; do
  if [ -e "$f" ]; then
    found=1
    break
  fi
done
if [ "$found" -eq 0 ]; then
  echo "error: no test files match $DIR/integration/*.test.* — nothing to run" >&2
  exit 1
fi

# Note: a directory arg breaks under Node 22's glob handling (it tries to load
# the directory as a module), so pass an explicit glob instead.
exec node --test --test-concurrency=1 "$@" "$DIR/integration/**/*.test.*"
