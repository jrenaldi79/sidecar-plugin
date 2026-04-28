#!/usr/bin/env bash
# _locate.sh — sourced by Sidecar scripts.
#
# Sets two variables:
#   SIDECAR_PLUGIN_DIR — read-only plugin root (where SKILL.md, proxy/, scripts/ live)
#   SIDECAR_STATE_DIR  — user-writable state dir holding .env.local
#
# State dir resolution order:
#   1. $SIDECAR_STATE_DIR env var if set
#   2. First $HOME/mnt/*/.sidecar/ directory containing .env.local
#   3. Default: $HOME/mnt/ClaudeCowork/.sidecar (created on demand)

# Plugin root = parent of the directory this file is in (scripts/_locate.sh -> skill root)
SIDECAR_PLUGIN_DIR="${SIDECAR_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ -z "${SIDECAR_STATE_DIR:-}" ]; then
  # search for an existing state dir under any mounted folder
  for cand in "$HOME"/mnt/*/.sidecar; do
    if [ -d "$cand" ] && [ -f "$cand/.env.local" ]; then
      SIDECAR_STATE_DIR="$cand"
      break
    fi
  done
fi

# Fallback default
: "${SIDECAR_STATE_DIR:=$HOME/mnt/ClaudeCowork/.sidecar}"

export SIDECAR_PLUGIN_DIR SIDECAR_STATE_DIR
