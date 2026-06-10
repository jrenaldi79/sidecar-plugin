#!/usr/bin/env bash
# usage.sh — fetch OpenRouter account usage: balance and day/week/month spend.
#
# Usage:
#   usage.sh           # human-readable summary
#   usage.sh --json    # machine-readable JSON (for on-demand visualization)
#
# Data sources — all live OpenRouter API, regular inference key only:
#   /api/v1/credits    total purchased / used -> balance
#   /api/v1/key        daily/weekly/monthly spend, key limit
#
# Deliberately NOT supported, do not reintroduce:
#   - /api/v1/activity (per-model rollups): requires an OpenRouter management
#     key, which can create/delete API keys — far too much privilege to ask
#     end users to hand to a tool.
#   - local history.log analysis: per-project, so it misrepresents
#     cross-project usage.
#
# Never echoes the key.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

MODE="human"
if [ "${1:-}" = "--json" ]; then MODE="json"; fi

if [ -z "${OPENROUTER_API_KEY:-}" ] || [ "${OPENROUTER_API_KEY:0:6}" != "sk-or-" ]; then
  echo "error: OPENROUTER_API_KEY not configured (in env or $ENV_FILE)" >&2
  echo "       run setup.sh, then: echo '<key>' | bash set-key.sh" >&2
  exit 1
fi

fetch() { # $1=path — body on stdout, empty on any failure
  curl -sS --max-time 10 "https://openrouter.ai$1" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" 2>/dev/null || true
}

RAW_CREDITS="$(fetch /api/v1/credits)" RAW_KEY="$(fetch /api/v1/key)" \
MODE="$MODE" python3 <<'PY'
import json, os

def load(name):
    try:
        return json.loads(os.environ.get(name) or '')
    except ValueError:
        return None

def data(doc):
    return doc['data'] if isinstance(doc, dict) and isinstance(doc.get('data'), dict) else None

report = {'credits': None, 'spend': None}

c = data(load('RAW_CREDITS'))
if c is not None:
    total = c.get('total_credits') or 0
    used  = c.get('total_usage') or 0
    report['credits'] = {'total_purchased': total, 'total_used': used,
                         'balance': round(total - used, 6)}

k = data(load('RAW_KEY'))
if k is not None:
    report['spend'] = {'daily': k.get('usage_daily'),
                       'weekly': k.get('usage_weekly'),
                       'monthly': k.get('usage_monthly'),
                       'limit': k.get('limit')}

if os.environ.get('MODE') == 'json':
    print(json.dumps(report, indent=2))
    raise SystemExit

def usd(v):
    return '$%.2f' % v if isinstance(v, (int, float)) else 'n/a'

print('=== OpenRouter usage ===')
c = report['credits']
if c:
    print('  balance: %s  (purchased %s, used %s all-time)'
          % (usd(c['balance']), usd(c['total_purchased']), usd(c['total_used'])))
else:
    print('  balance: unavailable (credits endpoint unreachable)')
s = report['spend']
if s:
    print('  spend:   today %s | this week %s | this month %s'
          % (usd(s['daily']), usd(s['weekly']), usd(s['monthly'])))
    if s['limit'] is not None:
        print('  key limit: %s' % usd(s['limit']))
PY
