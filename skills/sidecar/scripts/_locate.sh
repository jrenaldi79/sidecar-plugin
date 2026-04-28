#!/usr/bin/env bash
# _locate.sh — sourced by Sidecar scripts.
#
# Sets two variables:
#   SIDECAR_PLUGIN_DIR — read-only plugin root (where SKILL.md, proxy/, scripts/ live)
#   SIDECAR_STATE_DIR  — user-writable state dir holding .env.local
#
# State dir resolution order:
#   1. $SIDECAR_STATE_DIR env var if set
#   2. First $HOME/mnt/*/.sidecar/ that already contains .env.local (existing setup)
#   3. First mounted folder that's writable and not a system path (first-run fallback)
#   4. Hard default: $HOME/mnt/ClaudeCowork/.sidecar

# Plugin root = parent of the directory this file is in (scripts/_locate.sh -> skill root)
SIDECAR_PLUGIN_DIR="${SIDECAR_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# 2. Existing state dir
if [ -z "${SIDECAR_STATE_DIR:-}" ]; then
  for cand in "$HOME"/mnt/*/.sidecar; do
    if [ -d "$cand" ] && [ -f "$cand/.env.local" ]; then
      SIDECAR_STATE_DIR="$cand"
      break
    fi
  done
fi

# 3. First-run fallback: pick the first user-mounted, writable folder.
#    Skip system paths (outputs, uploads) and dotfile directories (.claude, .local-plugins, etc.)
if [ -z "${SIDECAR_STATE_DIR:-}" ]; then
  for cand in "$HOME"/mnt/*/; do
    [ -d "$cand" ] || continue
    name="$(basename "$cand")"
    case "$name" in
      outputs|uploads|.*) continue ;;
    esac
    if [ -w "$cand" ]; then
      SIDECAR_STATE_DIR="${cand%/}/.sidecar"
      break
    fi
  done
fi

# 4. Hard default — only used if literally nothing is mounted.
: "${SIDECAR_STATE_DIR:=$HOME/mnt/ClaudeCowork/.sidecar}"

export SIDECAR_PLUGIN_DIR SIDECAR_STATE_DIR
