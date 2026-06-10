#!/usr/bin/env bash
# usage.sh — fetch OpenRouter account usage: balance, spend, per-model activity.
# Per-model/per-date analytics (last 30 days) require the optional management key.
#
# Usage:
#   usage.sh           # human-readable summary
#   usage.sh --json    # machine-readable JSON (for on-demand visualization)
#
# Data sources — all live OpenRouter API, deliberately NOT the local
# history.log (which only sees asks from one project/state dir):
#   /api/v1/credits    regular key      total purchased / used -> balance
#   /api/v1/key        regular key      daily/weekly/monthly spend, limit
#   /api/v1/activity   management key   per-model daily rollups, 30 days
#
# OPENROUTER_MANAGEMENT_KEY in .env.local is optional (set via
# `set-key.sh --management`); without it the activity section is marked
# unavailable with a setup hint. Never echoes either key.

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

fetch() { # $1=path $2=bearer key — body on stdout, empty on any failure
  curl -sS --max-time 10 "https://openrouter.ai$1" \
    -H "Authorization: Bearer $2" 2>/dev/null || true
}

CREDITS_RAW="$(fetch /api/v1/credits "$OPENROUTER_API_KEY")"
KEYINFO_RAW="$(fetch /api/v1/key "$OPENROUTER_API_KEY")"

ACTIVITY_RAW="" HAS_MGMT=0
if [ -n "${OPENROUTER_MANAGEMENT_KEY:-}" ]; then
  HAS_MGMT=1
  ACTIVITY_RAW="$(fetch /api/v1/activity "$OPENROUTER_MANAGEMENT_KEY")"
fi

RAW_CREDITS="$CREDITS_RAW" RAW_KEY="$KEYINFO_RAW" RAW_ACTIVITY="$ACTIVITY_RAW" \
HAS_MGMT="$HAS_MGMT" MODE="$MODE" python3 <<'PY'
import json, os

def load(name):
    try:
        return json.loads(os.environ.get(name) or '')
    except ValueError:
        return None

credits  = load('RAW_CREDITS')
keyinfo  = load('RAW_KEY')
activity = load('RAW_ACTIVITY')
has_mgmt = os.environ.get('HAS_MGMT') == '1'
mode     = os.environ.get('MODE', 'human')

report = {'credits': None, 'spend': None, 'activity': {'available': False}}

if isinstance(credits, dict) and isinstance(credits.get('data'), dict):
    d = credits['data']
    total = d.get('total_credits') or 0
    used  = d.get('total_usage') or 0
    report['credits'] = {'total_purchased': total, 'total_used': used,
                         'balance': round(total - used, 6)}

if isinstance(keyinfo, dict) and isinstance(keyinfo.get('data'), dict):
    d = keyinfo['data']
    report['spend'] = {'daily': d.get('usage_daily'),
                       'weekly': d.get('usage_weekly'),
                       'monthly': d.get('usage_monthly'),
                       'limit': d.get('limit')}

SUM_KEYS = ('usage', 'requests', 'prompt_tokens', 'completion_tokens',
            'reasoning_tokens')
act = report['activity']
if has_mgmt and isinstance(activity, dict) and isinstance(activity.get('data'), list):
    by_model, by_date = {}, {}
    for r in activity['data']:
        m = by_model.setdefault(r.get('model') or '?',
                                dict.fromkeys(SUM_KEYS, 0))
        for k in SUM_KEYS:
            m[k] += r.get(k) or 0
        d = by_date.setdefault(r.get('date') or '?',
                               {'usage': 0, 'requests': 0})
        d['usage'] += r.get('usage') or 0
        d['requests'] += r.get('requests') or 0
    act['available'] = True
    act['rows'] = activity['data']
    act['by_model'] = sorted(
        ({'model': k, **{s: round(v[s], 6) for s in SUM_KEYS}}
         for k, v in by_model.items()),
        key=lambda a: -a['usage'])
    act['by_date'] = sorted(
        ({'date': k, 'usage': round(v['usage'], 6), 'requests': v['requests']}
         for k, v in by_date.items()),
        key=lambda a: a['date'])
elif has_mgmt:
    act['hint'] = ('management key is set but /api/v1/activity returned no '
                   'usable data — verify the key at '
                   'https://openrouter.ai/settings/management-keys')
else:
    act['hint'] = ('per-model analytics need a management key: create one at '
                   'https://openrouter.ai/settings/management-keys, then run '
                   'set-key.sh --management')

if mode == 'json':
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
if act['available']:
    print('  top models (last 30 days):')
    print('    %-45s %10s %9s %12s' % ('model', 'cost', 'requests', 'tokens'))
    for a in act['by_model'][:10]:
        toks = a['prompt_tokens'] + a['completion_tokens'] + a['reasoning_tokens']
        print('    %-45s %10s %9d %12d'
              % (a['model'][:45], usd(a['usage']), a['requests'], toks))
else:
    print('  per-model activity: unavailable')
    print('    %s' % act['hint'])
PY
