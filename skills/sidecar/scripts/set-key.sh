#!/usr/bin/env bash
# set-key.sh — inject the OpenRouter API key into .env.local.
#
# Why this script exists: on Cowork's Windows host, the connected folder is
# a virtiofs mount backed by OneDrive. Several common write patterns fail:
#
#   • The Edit/Write file tools — files created by bash `cp` end up with
#     NTFS ACLs owned by the virtiofs driver, not the user's Windows token.
#     Subsequent file-tool writes fail with EPERM.
#   • `sed -i` — its rename-into-place dance triggers OneDrive sync conflict
#     resolution, which deletes the new file. The file silently disappears.
#   • virtiofs page cache — Windows-side writes aren't always seen by Linux
#     processes until the inode is touched from the Linux side.
#
# Safe pattern: read the file in memory, transform, write back via bash
# redirect-truncate (`>`). That keeps the inode stable, ACLs user-owned,
# and OneDrive sees an in-place update rather than a delete+create.
#
# Usage:
#   bash set-key.sh <openrouter-api-key>          # arg
#   echo <openrouter-api-key> | bash set-key.sh   # stdin (preferred — keeps
#                                                   the key out of the
#                                                   process command line)
#
# Regular inference keys only — Sidecar deliberately has no concept of an
# OpenRouter management key (it can create/delete API keys; too much
# privilege to ask users for). Never echoes the key.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"

# Read key from arg or stdin.
if [ "$#" -ge 1 ]; then
  KEY="$1"
else
  if [ -t 0 ]; then
    cat >&2 <<EOF
usage:
  bash set-key.sh <openrouter-api-key>
  echo <openrouter-api-key> | bash set-key.sh

Get a key at https://openrouter.ai/keys (must start with sk-or-).
EOF
    exit 1
  fi
  KEY="$(cat | tr -d '\r\n')"
fi

if [ -z "${KEY// /}" ]; then
  echo "set-key.sh: empty key" >&2
  exit 2
fi

# Light validation. Refuse to write a clearly invalid key.
case "$KEY" in
  sk-or-*) ;;
  *)
    echo "set-key.sh: key doesn't start with 'sk-or-' — refusing to write." >&2
    echo "             (All OpenRouter keys use that prefix. If you meant a" >&2
    echo "             non-OpenRouter key, edit \$ENV_FILE manually.)" >&2
    exit 3
    ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "set-key.sh: $ENV_FILE not found — run setup.sh first" >&2
  exit 1
fi

# Read content into memory, replace the OPENROUTER_API_KEY line (or append
# if missing), write back via redirect-truncate. NEVER echo the key.
NEW_CONTENT=$(awk -v key="$KEY" '
  /^OPENROUTER_API_KEY=/ {
    print "OPENROUTER_API_KEY=\"" key "\""
    saw=1; next
  }
  { print }
  END {
    if (!saw) print "OPENROUTER_API_KEY=\"" key "\""
  }
' "$ENV_FILE")

if [ -z "$NEW_CONTENT" ]; then
  echo "set-key.sh: refused to overwrite $ENV_FILE with empty content" >&2
  exit 4
fi

printf '%s\n' "$NEW_CONTENT" > "$ENV_FILE"

# Confirm the update without echoing the key.
if grep -q '^OPENROUTER_API_KEY="sk-or-' "$ENV_FILE"; then
  TAIL="${KEY: -4}"
  echo "OPENROUTER_API_KEY updated in $ENV_FILE (sk-or-…$TAIL)"
else
  echo "set-key.sh: write completed but key not detected in file — check $ENV_FILE manually" >&2
  exit 5
fi
