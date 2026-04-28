#!/usr/bin/env bash
# status.sh — report whether Sidecar is running and its current configuration.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"

echo "=== Sidecar status ==="
echo "  plugin dir: $SIDECAR_PLUGIN_DIR"
echo "  state dir:  $SIDECAR_STATE_DIR"

if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
  echo "  config:"
  echo "    PORT             = ${PORT:-3000}"
  echo "    COMPLETION_MODEL = ${COMPLETION_MODEL:-<unset>}"
  echo "    REASONING_MODEL  = ${REASONING_MODEL:-<unset>}"
  echo "    ANTHROPIC_BASE_URL = ${ANTHROPIC_BASE_URL:-<unset>}"
  if [ -n "${OPENROUTER_API_KEY:-}" ] && [ "${OPENROUTER_API_KEY:0:6}" = "sk-or-" ]; then
    echo "    OPENROUTER_API_KEY = sk-or-…${OPENROUTER_API_KEY: -4}"
  else
    echo "    OPENROUTER_API_KEY = <missing or invalid>"
  fi
else
  echo "  config: $ENV_FILE not found — run setup.sh"
fi

PORT="${PORT:-3000}"
PIDS=$(pgrep -f "node.*node_modules/anthropic-proxy/index" 2>/dev/null || true)
if [ -n "$PIDS" ]; then
  echo "  process: running (pids: $PIDS)"
else
  echo "  process: not running"
fi

if (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  echo "  port $PORT: listening"
else
  echo "  port $PORT: not listening"
fi
