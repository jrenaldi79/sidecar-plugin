#!/usr/bin/env bash
# test.sh — verify the Sidecar plugin install end-to-end.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/node_modules/anthropic-proxy/index.js"
PASS=0; FAIL=0
note() { echo "  - $*"; }
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# writable log path
for cand in "$HOME/sidecar-test.log" "/tmp/sidecar-test.log" "./sidecar-test.log"; do
  if : > "$cand" 2>/dev/null; then LOG="$cand"; break; fi
done
LOG="${LOG:-$HOME/sidecar-test.log}"

echo "=== environment ==="
echo "  session HOME: $HOME"
echo "  hostname:     $(hostname)"
echo "  plugin dir:   $SIDECAR_PLUGIN_DIR"
echo "  state dir:    $SIDECAR_STATE_DIR"
echo "  env file:     $ENV_FILE"
echo "  log:          $LOG"
echo "  node:         $(command -v node || echo MISSING)  $(node --version 2>/dev/null)"
echo "  claude:       $(command -v claude || echo MISSING) $(claude --version 2>/dev/null)"

echo
echo "=== install check ==="
[ -f "$PROXY_ENTRY" ] && pass "vendored proxy installed" || fail "vendored proxy missing at $PROXY_ENTRY"
[ -f "$ENV_FILE" ] && pass ".env.local present" || fail ".env.local missing — run setup.sh"

if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi
if [ -n "${OPENROUTER_API_KEY:-}" ] && [ "${OPENROUTER_API_KEY:0:6}" = "sk-or-" ]; then
  pass "OPENROUTER_API_KEY looks valid"
else
  fail "OPENROUTER_API_KEY missing or invalid"
fi

echo
echo "=== boot proxy ==="
bash "$SCRIPT_DIR/start.sh" > "$LOG" 2>&1 &
PROXY_PID=$!
PORT="${PORT:-3000}"
for i in $(seq 1 20); do
  (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
  sleep 0.25
done
if (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  pass "proxy listening on port $PORT (pid $PROXY_PID)"
else
  fail "proxy did not come up — check $LOG"
  tail -20 "$LOG" | sed 's/^/    /'
  echo "  PASS: $PASS   FAIL: $FAIL"
  exit 1
fi

echo
echo "=== curl probe ==="
RESP=$(curl -sS "http://127.0.0.1:$PORT/v1/messages" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"client-sent-anything","max_tokens":20,"messages":[{"role":"user","content":"say ok"}]}')
UPSTREAM=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('model','?'))" 2>/dev/null || echo "?")
TEXT=$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',[{}])[0].get('text','?'))" 2>/dev/null || echo "?")
note "upstream model: $UPSTREAM"
note "response text:  $TEXT"
if [ "$UPSTREAM" = "${COMPLETION_MODEL:-?}" ]; then
  pass "upstream matches COMPLETION_MODEL"
else
  fail "upstream ($UPSTREAM) != COMPLETION_MODEL (${COMPLETION_MODEL:-<unset>})"
fi
[ -n "$TEXT" ] && [ "$TEXT" != "?" ] && pass "got non-empty response" || fail "empty response"

echo
echo "=== claude CLI through proxy ==="
CLI_OUT=$(ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" ANTHROPIC_AUTH_TOKEN="" \
  timeout 25 claude -p "Reply with one short sentence containing the word 'pong'." </dev/null 2>&1)
note "CLI output: $CLI_OUT"
echo "$CLI_OUT" | grep -qi pong && pass "claude CLI produced expected output" || fail "claude CLI output missing 'pong'"

echo
echo "=== proxy still alive? ==="
kill -0 "$PROXY_PID" 2>/dev/null && pass "proxy survived the test" || fail "proxy crashed"

kill "$PROXY_PID" 2>/dev/null

echo
echo "=== summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: all checks passed"
else
  echo "  RESULT: failures detected — see $LOG"
fi
exit "$FAIL"
