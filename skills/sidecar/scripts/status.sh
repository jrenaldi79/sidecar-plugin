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
PIDS=$(pgrep -f "node.*sidecar.*proxy/bundle\.cjs" 2>/dev/null || true)
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

# Recent activity — written by ask.sh, one line per run
# (UTC time, model, seconds, exit code, input/output tokens).
HIST="$SIDECAR_STATE_DIR/history.log"
if [ -s "$HIST" ]; then
  echo "  recent asks:"
  tail -5 "$HIST" | sed 's/^/    /'
fi

# OpenRouter credit — best-effort, silently skipped on any failure.
if [ -n "${OPENROUTER_API_KEY:-}" ] && [ "${OPENROUTER_API_KEY:0:6}" = "sk-or-" ]; then
  CREDIT=$(curl -sS --max-time 5 "https://openrouter.ai/api/v1/key" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)["data"]
    limit = d.get("limit")
    usage = d.get("usage") or 0
    lim = "unlimited" if limit is None else "$%.2f limit" % limit
    print("$%.2f used / %s" % (usage, lim))
except Exception:
    pass
' 2>/dev/null)
  if [ -n "$CREDIT" ]; then
    echo "  openrouter credit: $CREDIT"
  fi
fi
