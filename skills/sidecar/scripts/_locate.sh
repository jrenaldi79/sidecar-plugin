#!/usr/bin/env bash
# _locate.sh — sourced by Sidecar scripts.
#
# Sets two variables:
#   SIDECAR_PLUGIN_DIR — read-only plugin root (where SKILL.md, proxy/, scripts/ live)
#   SIDECAR_STATE_DIR  — user-writable state dir holding .env.local
#
# State dir name conventions:
#   - COWORK:    <connected-folder>/sidecar-state/   (sandbox default; works on
#                                                     Mac, Linux, Windows hosts)
#   - LEGACY:    <connected-folder>/.sidecar/        (recognized for back-compat; do NOT
#                                                     create new ones — the leading dot
#                                                     breaks Windows/NTFS/OneDrive virtiofs)
#   - HOST:      $HOME/.sidecar-state/               (Claude Code on a real host —
#                                                     no $HOME/mnt mount layout exists)
#
# Resolution order:
#   1. $SIDECAR_STATE_DIR env var if set (explicit override always wins)
#   2. First $HOME/mnt/*/sidecar-state/  containing .env.local  (Cowork)
#   3. First $HOME/mnt/*/.sidecar/       containing .env.local  (legacy)
#   4. $HOME/.sidecar-state/             containing .env.local  (host)
#   5. First user-mounted, writable folder + /sidecar-state/    (Cowork first run)
#   6. $HOME/.sidecar-state when no $HOME/mnt exists            (host first run)
#   7. Hard default: $HOME/mnt/ClaudeCowork/sidecar-state

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

# 4. Host: existing ~/.sidecar-state (Claude Code outside the sandbox).
#    Checked after the mnt scan so a Cowork session never shadows its own
#    mounted state with a host-side leftover.
if [ -z "${SIDECAR_STATE_DIR:-}" ] && [ -f "$HOME/.sidecar-state/.env.local" ]; then
  SIDECAR_STATE_DIR="$HOME/.sidecar-state"
fi

# 5. Cowork first-run fallback: pick the first user-mounted, writable folder
#    and use sidecar-state/ inside it. Skip system paths and dotfile dirs.
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

# 6. Host first-run: no Cowork mount layout at all -> ~/.sidecar-state.
#    (Dotfile naming is fine here: the virtiofs/OneDrive concerns only apply
#    to sandbox-mounted folders, not a real host $HOME.)
if [ -z "${SIDECAR_STATE_DIR:-}" ] && [ ! -d "$HOME/mnt" ]; then
  SIDECAR_STATE_DIR="$HOME/.sidecar-state"
fi

# 7. Hard default — mnt exists but holds nothing usable.
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
