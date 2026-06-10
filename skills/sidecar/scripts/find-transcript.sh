#!/usr/bin/env bash
# find-transcript.sh — locate the parent session's JSONL transcript.
#
# Works in both environments:
#   Cowork sandbox: $HOME/mnt/.claude/projects   (bind mount of the host dir)
#   Claude Code:    $HOME/.claude/projects        (the real thing)
# The parent transcript is taken to be the most recently modified .jsonl —
# the active session is being written continuously, so it always wins.

set -u

PROJECTS_DIR=""
for cand in "$HOME/mnt/.claude/projects" "$HOME/.claude/projects"; do
  if [ -d "$cand" ]; then
    PROJECTS_DIR="$cand"
    break
  fi
done

if [ -z "$PROJECTS_DIR" ]; then
  echo "find-transcript: no .claude/projects found under \$HOME/mnt or \$HOME" >&2
  echo "                 (in Cowork: is the parent .claude bind-mount enabled?)" >&2
  exit 1
fi

if [ "${1:-}" = "--dir" ]; then
  echo "$PROJECTS_DIR"
  exit 0
fi

# Newest .jsonl via [ -nt ] — portable across BSD and GNU userlands
# (find -printf is GNU-only and silently fails on macOS).
LATEST=""
while IFS= read -r f; do
  if [ -z "$LATEST" ] || [ "$f" -nt "$LATEST" ]; then
    LATEST="$f"
  fi
done < <(find "$PROJECTS_DIR" -type f -name '*.jsonl' 2>/dev/null)

if [ -z "$LATEST" ]; then
  echo "find-transcript: no .jsonl found under $PROJECTS_DIR" >&2
  exit 1
fi

echo "$LATEST"
