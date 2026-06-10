#!/usr/bin/env bash
# run-integration.sh — Tier 1: mock-based integration tests. No network, no key.
# Usage: bash tests/run-integration.sh [extra node --test args]
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
# Note: a directory arg breaks under Node 22's glob handling (it tries to load
# the directory as a module), so pass an explicit glob instead.
exec node --test --test-concurrency=1 "$@" "$DIR/integration/**/*.test.*"
