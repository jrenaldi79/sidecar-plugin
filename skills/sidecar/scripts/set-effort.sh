#!/usr/bin/env bash
# set-effort.sh — set the PERSISTENT default reasoning effort in .env.local.
#
# Usage:
#   bash set-effort.sh low|medium|high   # cap/raise reasoning effort
#   bash set-effort.sh default           # clear -> each provider's default
#
# Reasoning tokens bill as OUTPUT tokens, so effort is the biggest per-call
# cost lever after model choice. Per-call override: `ask.sh --effort <level>`
# (doesn't touch this persistent value). Same redirect-truncate write pattern
# as set-key.sh — never use Edit/Write tools on .env.local.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"

LEVEL="${1:-}"
case "$LEVEL" in
  low|medium|high) VALUE="$LEVEL" ;;
  default)         VALUE="" ;;
  *)
    echo "set-effort.sh: expected low|medium|high|default, got '${LEVEL:-<none>}'" >&2
    exit 2
    ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "set-effort.sh: $ENV_FILE not found — run setup.sh first" >&2
  exit 1
fi

# Replace the SIDECAR_REASONING_EFFORT line (or append if missing), write
# back via redirect-truncate (virtiofs/OneDrive-safe — see set-key.sh).
NEW_CONTENT=$(awk -v val="$VALUE" '
  /^SIDECAR_REASONING_EFFORT=/ {
    print "SIDECAR_REASONING_EFFORT=\"" val "\""
    saw=1; next
  }
  { print }
  END {
    if (!saw) print "SIDECAR_REASONING_EFFORT=\"" val "\""
  }
' "$ENV_FILE")

if [ -z "$NEW_CONTENT" ]; then
  echo "set-effort.sh: refused to overwrite $ENV_FILE with empty content" >&2
  exit 3
fi

printf '%s\n' "$NEW_CONTENT" > "$ENV_FILE"

if [ -n "$VALUE" ]; then
  echo "SIDECAR_REASONING_EFFORT set to \"$VALUE\" in $ENV_FILE"
else
  echo "SIDECAR_REASONING_EFFORT cleared in $ENV_FILE (provider default)"
fi
