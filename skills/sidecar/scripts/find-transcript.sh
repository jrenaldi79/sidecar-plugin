#!/usr/bin/env bash
# find-transcript.sh — locate the parent Cowork session's JSONL transcript.

set -u

PROJECTS_DIR="$HOME/mnt/.claude/projects"

if [ "${1:-}" = "--dir" ]; then
  if [ -d "$PROJECTS_DIR" ]; then
    echo "$PROJECTS_DIR"
    exit 0
  else
    echo "find-transcript: $PROJECTS_DIR not present" >&2
    exit 1
  fi
fi

if [ ! -d "$PROJECTS_DIR" ]; then
  echo "find-transcript: $PROJECTS_DIR not present (is parent .claude bind-mount enabled?)" >&2
  exit 1
fi

LATEST=$(find "$PROJECTS_DIR" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)

if [ -z "$LATEST" ]; then
  echo "find-transcript: no .jsonl found under $PROJECTS_DIR" >&2
  exit 1
fi

echo "$LATEST"
