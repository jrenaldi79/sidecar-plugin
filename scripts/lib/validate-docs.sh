#!/usr/bin/env bash
# validate-docs.sh — CLAUDE.md drift detection (warn-only, never blocks).
# Pre-commit mode (default): warn when source/script files are staged
# without a CLAUDE.md update in the same commit.
# --full: compare files named in CLAUDE.md's Directory Structure section
# against what actually exists on disk; exit 1 on drift.

set -u
ROOT=$(git rev-parse --show-toplevel)
DOC="$ROOT/CLAUDE.md"

if [ "${1:-}" = "--full" ]; then
  [ -f "$DOC" ] || { echo "FAIL: CLAUDE.md missing" >&2; exit 1; }
  DRIFT=0
  # Every path-looking token in the Directory Structure code block must exist.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -e "$ROOT/$path" ]; then
      echo "DRIFT: CLAUDE.md mentions '$path' but it does not exist" >&2
      DRIFT=1
    fi
  done < <(awk '/^## Directory Structure/,/^## [^D]/' "$DOC" \
            | grep -oE '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+\.[a-z]+' | sort -u)
  exit "$DRIFT"
fi

# Pre-commit mode: warn only.
staged=$(git diff --cached --name-only --diff-filter=ACMRD)
if echo "$staged" | grep -qE '^(skills/sidecar/scripts/|skills/sidecar/proxy/|scripts/|build\.sh)' \
   && ! echo "$staged" | grep -q '^CLAUDE\.md$'; then
  echo "WARN: source/script files staged without CLAUDE.md — update it if architecture or commands changed." >&2
fi
exit 0
