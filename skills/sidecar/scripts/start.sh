#!/usr/bin/env bash
# start.sh — boot the Sidecar proxy.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
# Honor SIDECAR_BUNDLE_OVERRIDE so a power user can point at a hot-patched
# bundle without rebuilding the plugin (useful for debugging upstream bugs).
PROXY_ENTRY="${SIDECAR_BUNDLE_OVERRIDE:-$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs}"

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

cd "$(dirname "$PROXY_ENTRY")"
exec node "$(basename "$PROXY_ENTRY")"
