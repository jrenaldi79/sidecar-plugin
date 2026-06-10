#!/usr/bin/env bash
# list-models.sh — fetch the live OpenRouter model catalog, optionally filtered.
#
# Usage:
#   list-models.sh                # all models
#   list-models.sh gemini         # filter on substring (case-insensitive)
#   list-models.sh claude sonnet  # multi-token AND match
#   FORMAT=slugs list-models.sh   # only slugs, one per line
#   FORMAT=json  list-models.sh   # raw JSON for downstream parsing

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "error: OPENROUTER_API_KEY not set (in env or $ENV_FILE)" >&2
  exit 1
fi

FILTERS_JSON=$(python3 -c "import json,sys; print(json.dumps([a.lower() for a in sys.argv[1:]]))" "$@")

RAW=$(curl -sS "https://openrouter.ai/api/v1/models" \
  -H "Authorization: Bearer $OPENROUTER_API_KEY")

if ! echo "$RAW" | python3 -c "import json,sys; json.load(sys.stdin)" >/dev/null 2>&1; then
  echo "error: bad response from OpenRouter:" >&2
  echo "$RAW" | head -c 400 >&2
  exit 2
fi

case "${FORMAT:-table}" in
  json)
    echo "$RAW"
    ;;
  slugs)
    echo "$RAW" | python3 -c "
import json, sys
filters = json.loads('$FILTERS_JSON')
data = json.load(sys.stdin)['data']
for m in data:
    name = m['id'].lower()
    if all(f in name for f in filters):
        print(m['id'])
"
    ;;
  table|*)
    echo "$RAW" | python3 -c "
import json, sys
filters = json.loads('$FILTERS_JSON')
data = json.load(sys.stdin)['data']
matched = [m for m in data if all(f in m['id'].lower() for f in filters)]
if not matched:
    print('(no models matched filter)')
    sys.exit(0)
def per_million(m, key):
    # catalog pricing values are \$/token strings; show \$/M tokens
    try:
        v = float((m.get('pricing') or {}).get(key))
    except (TypeError, ValueError):
        return '?'
    return 'free' if v == 0 else '\$%.2f' % (v * 1e6)
print(f'{\"slug\":55} {\"context\":>10} {\"\$/M in\":>9} {\"\$/M out\":>9}  short description')
print('-' * 116)
for m in matched:
    ctx = m.get('context_length') or '?'
    desc = (m.get('name') or '')[:30]
    print(f\"{m['id'][:55]:55} {str(ctx):>10} {per_million(m, 'prompt'):>9} {per_million(m, 'completion'):>9}  {desc}\")
print()
print(f'{len(matched)} model(s) matched.')
"
    ;;
esac
