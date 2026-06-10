#!/usr/bin/env bash
# _locate.sh — sourced by Sidecar scripts.
#
# Sets two variables:
#   SIDECAR_PLUGIN_DIR — read-only plugin root (where SKILL.md, proxy/, scripts/ live)
#   SIDECAR_STATE_DIR  — user-writable state dir holding .env.local
#
# State dir name conventions:
#   - PRIMARY:   <connected-folder>/sidecar-state/   (default; works on Mac, Linux, Windows)
#   - LEGACY:    <connected-folder>/.sidecar/        (recognized for back-compat; do NOT
#                                                     create new ones — the leading dot
#                                                     breaks Windows/NTFS/OneDrive virtiofs)
#
# Resolution order:
#   1. $SIDECAR_STATE_DIR env var if set (explicit override always wins)
#   2. First $HOME/mnt/*/sidecar-state/  containing .env.local  (preferred)
#   3. First $HOME/mnt/*/.sidecar/       containing .env.local  (legacy)
#   4. First user-mounted, writable folder + /sidecar-state/    (first-run fallback)
#   5. Hard default: $HOME/mnt/ClaudeCowork/sidecar-state

# Plugin root = parent of the directory this file is in (scripts/_locate.sh -> skill root)
SIDECAR_PLUGIN_DIR="${SIDECAR_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# 2 + 3. Existing state dir (preferred name first, legacy second).
if [ -z "${SIDECAR_STATE_DIR:-}" ]; then
  for cand in "$HOME"/mnt/*/sidecar-state "$HOME"/mnt/*/.sidecar; do
    if [ -d "$cand" ] && [ -f "$cand/.env.local" ]; then
      SIDECAR_STATE_DIR="$cand"
      break
    fi
  done
fi

# 4. First-run fallback: pick the first user-mounted, writable folder and use
#    sidecar-state/ inside it. Skip system paths and dotfile directories.
if [ -z "${SIDECAR_STATE_DIR:-}" ]; then
  for cand in "$HOME"/mnt/*/; do
    [ -d "$cand" ] || continue
    name="$(basename "$cand")"
    case "$name" in
      outputs|uploads|.*) continue ;;
    esac
    if [ -w "$cand" ]; then
      SIDECAR_STATE_DIR="${cand%/}/sidecar-state"
      break
    fi
  done
fi

# 5. Hard default — only used if literally nothing is mounted.
: "${SIDECAR_STATE_DIR:=$HOME/mnt/ClaudeCowork/sidecar-state}"

# Proxy entry resolution (shared by start.sh, ask.sh, setup.sh, test.sh):
#   1. $SIDECAR_BUNDLE_OVERRIDE — hot-patch escape hatch, always wins
#   2. proxy/bundle.cjs        — full dev bundle (gitignored; built by build.sh)
#   3. proxy/bundle-min.cjs    — tracked minified bundle, the fallback that
#                                makes marketplace installs (git clones, which
#                                have no bundle.cjs) work out of the box
if [ -n "${SIDECAR_BUNDLE_OVERRIDE:-}" ]; then
  SIDECAR_PROXY_ENTRY="$SIDECAR_BUNDLE_OVERRIDE"
elif [ -f "$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs" ]; then
  SIDECAR_PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs"
else
  SIDECAR_PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/bundle-min.cjs"
fi

export SIDECAR_PLUGIN_DIR SIDECAR_STATE_DIR SIDECAR_PROXY_ENTRY
