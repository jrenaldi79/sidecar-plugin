#!/usr/bin/env bash
# start.sh — boot the Sidecar proxy.
# Run in background: bash start.sh > /tmp/sidecar.log 2>&1 &

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/node_modules/anthropic-proxy/index.js"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "warning: $ENV_FILE not found — run setup.sh first" >&2
fi

if [ ! -f "$PROXY_ENTRY" ]; then
  echo "error: vendored proxy missing at $PROXY_ENTRY" >&2
  exit 1
fi

# Run from the plugin's proxy dir so node finds node_modules correctly.
cd "$SIDECAR_PLUGIN_DIR/proxy"
exec node node_modules/anthropic-proxy/index.js
