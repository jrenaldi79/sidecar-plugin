#!/usr/bin/env bash
# start.sh — boot the Sidecar proxy.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "warning: $ENV_FILE not found — run setup.sh first" >&2
fi

if [ ! -f "$PROXY_ENTRY" ]; then
  echo "error: bundled proxy missing at $PROXY_ENTRY" >&2
  exit 1
fi

cd "$SIDECAR_PLUGIN_DIR/proxy"
exec node bundle.cjs
