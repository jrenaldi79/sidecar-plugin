#!/usr/bin/env bash
# set-model.sh — change the model Sidecar forwards to.
#
# Usage:
#   set-model.sh <slug>                   # set both COMPLETION_MODEL and REASONING_MODEL
#   set-model.sh <completion> <reasoning>  # set independently
#
# Validates against the live OpenRouter catalog before writing.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  cat >&2 <<EOF
usage:
  set-model.sh <slug>                    # apply to both COMPLETION_MODEL and REASONING_MODEL
  set-model.sh <completion> <reasoning>  # apply independently

example:
  set-model.sh google/gemini-3-flash-preview
  set-model.sh google/gemini-2.5-flash deepseek/deepseek-v3.2
EOF
  exit 1
fi

COMPLETION="$1"
REASONING="${2:-$1}"

if [ ! -f "$ENV_FILE" ]; then
  echo "error: $ENV_FILE not found — run setup.sh first" >&2
  exit 1
fi

set -a; source "$ENV_FILE"; set +a
if [ -z "${OPENROUTER_API_KEY:-}" ] || [ "${OPENROUTER_API_KEY:0:6}" != "sk-or-" ]; then
  echo "error: OPENROUTER_API_KEY in $ENV_FILE looks invalid" >&2
  exit 1
fi

# Validate against catalog
RAW=$(curl -sS "https://openrouter.ai/api/v1/models" -H "Authorization: Bearer $OPENROUTER_API_KEY")
echo "$RAW" | python3 -c "
import json, sys
data = json.load(sys.stdin)['data']
known = {m['id'] for m in data}
slugs = ['$COMPLETION', '$REASONING']
missing = [s for s in slugs if s not in known]
if missing:
    print('Unknown slug(s): ' + ', '.join(missing), file=sys.stderr)
    print('Try: bash list-models.sh <keyword>', file=sys.stderr)
    sys.exit(2)
" || exit 2

# Read .env.local into memory, transform, write back via redirect-truncate.
# (Plugin sandbox can mutate state dir but we need to avoid mv on Mac-mounted FS.)
NEW_CONTENT=$(awk -v comp="$COMPLETION" -v reas="$REASONING" '
  /^COMPLETION_MODEL=/ { print "COMPLETION_MODEL=\"" comp "\""; saw_c=1; next }
  /^REASONING_MODEL=/  { print "REASONING_MODEL=\""  reas "\""; saw_r=1; next }
  { print }
  END {
    if (!saw_c) print "COMPLETION_MODEL=\"" comp "\""
    if (!saw_r) print "REASONING_MODEL=\""  reas "\""
  }
' "$ENV_FILE")

if [ -z "$NEW_CONTENT" ]; then
  echo "error: refused to overwrite $ENV_FILE with empty content" >&2
  exit 3
fi

printf '%s\n' "$NEW_CONTENT" > "$ENV_FILE"

echo "updated $ENV_FILE:"
echo "  COMPLETION_MODEL = $COMPLETION"
echo "  REASONING_MODEL  = $REASONING"

# Restart proxy if running
PIDS=$(pgrep -f "node.*node_modules/anthropic-proxy/index" 2>/dev/null || true)
if [ -n "$PIDS" ]; then
  echo "restarting proxy (was pid: $PIDS)..."
  kill $PIDS 2>/dev/null
  sleep 0.5
  bash "$SCRIPT_DIR/start.sh" > /tmp/sidecar.log 2>&1 &
  sleep 1
  if (echo > "/dev/tcp/127.0.0.1/${PORT:-3000}") 2>/dev/null; then
    echo "proxy back up on port ${PORT:-3000}"
  else
    echo "warning: proxy didn't come back up — check /tmp/sidecar.log" >&2
  fi
else
  echo "proxy not running; new model will apply on next start.sh"
fi
