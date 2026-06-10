#!/usr/bin/env bash
# refresh-defaults.sh — view or update the vendor → model alias map that
# ask.sh --model <vendor> resolves through (<state>/defaults.env).
#
# Usage:
#   refresh-defaults.sh                  # show current map + the newest
#                                        # catalog candidates per vendor
#   refresh-defaults.sh <vendor> <slug>  # validate <slug> against the live
#                                        # catalog, then map <vendor> to it
#
# Env:
#   SIDECAR_CATALOG_FILE — read the catalog JSON from a file instead of
#                          querying OpenRouter (offline/testing hook)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
DEFAULTS_FILE="$SIDECAR_STATE_DIR/defaults.env"

if [ "$#" -ne 0 ] && [ "$#" -ne 2 ]; then
  echo "usage: refresh-defaults.sh [<vendor> <slug>]" >&2
  exit 1
fi

# ---- fetch the catalog (file hook first, then live) ----
if [ -n "${SIDECAR_CATALOG_FILE:-}" ]; then
  RAW=$(cat "$SIDECAR_CATALOG_FILE")
else
  if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "error: OPENROUTER_API_KEY not set (in env or $ENV_FILE)" >&2
    exit 1
  fi
  RAW=$(curl -sS "https://openrouter.ai/api/v1/models" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY")
fi
if ! echo "$RAW" | python3 -c "import json,sys; json.load(sys.stdin)" >/dev/null 2>&1; then
  echo "error: bad catalog response:" >&2
  echo "$RAW" | head -c 400 >&2
  exit 2
fi

# ---- no args: show map + newest candidates per vendor ----
if [ "$#" -eq 0 ]; then
  echo "=== current aliases ($DEFAULTS_FILE) ==="
  if [ -f "$DEFAULTS_FILE" ]; then
    grep -E '^SIDECAR_MODEL_' "$DEFAULTS_FILE" | sed 's/^/  /'
  else
    echo "  (missing — run setup.sh to seed it)"
  fi
  echo
  echo "=== newest catalog candidates per vendor (by release date) ==="
  echo "$RAW" | python3 -c "
import json, sys
prefixes = {'gemini': 'google/gemini', 'gpt': 'openai/', 'deepseek': 'deepseek/',
            'grok': 'x-ai/', 'llama': 'meta-llama/'}
data = json.load(sys.stdin)['data']
for vendor, prefix in prefixes.items():
    hits = sorted((m for m in data if m['id'].startswith(prefix)),
                  key=lambda m: m.get('created') or 0, reverse=True)[:3]
    print(f'  {vendor}:')
    for m in hits:
        print(f\"    {m['id']}\")
"
  echo
  echo "Remap with: bash $SCRIPT_DIR/refresh-defaults.sh <vendor> <slug>"
  exit 0
fi

# ---- two args: validate slug, then rewrite the alias line ----
VENDOR="$1"
SLUG="$2"
UP=$(printf '%s' "$VENDOR" | tr 'a-z-' 'A-Z_')

echo "$RAW" | python3 -c "
import json, sys
known = {m['id'] for m in json.load(sys.stdin)['data']}
if '$SLUG' not in known:
    print('Unknown slug: $SLUG', file=sys.stderr)
    print('Try: bash list-models.sh $VENDOR', file=sys.stderr)
    sys.exit(2)
" || exit 2

# Read into memory, replace-or-append, write back via redirect-truncate
# (no mv/sed -i — virtiofs/OneDrive constraints, see set-key.sh).
if [ -f "$DEFAULTS_FILE" ]; then
  NEW_CONTENT=$(awk -v up="$UP" -v slug="$SLUG" '
    $0 ~ ("^SIDECAR_MODEL_" up "=") { print "SIDECAR_MODEL_" up "=\"" slug "\""; saw=1; next }
    { print }
    END { if (!saw) print "SIDECAR_MODEL_" up "=\"" slug "\"" }
  ' "$DEFAULTS_FILE")
else
  NEW_CONTENT="SIDECAR_MODEL_$UP=\"$SLUG\""
fi

if [ -z "$NEW_CONTENT" ]; then
  echo "error: refused to overwrite $DEFAULTS_FILE with empty content" >&2
  exit 3
fi
printf '%s\n' "$NEW_CONTENT" > "$DEFAULTS_FILE"

echo "updated $DEFAULTS_FILE:"
echo "  SIDECAR_MODEL_$UP = $SLUG"
echo "ask.sh --model $VENDOR now routes to $SLUG"
