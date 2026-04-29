#!/usr/bin/env bash
# test.sh — verify the Sidecar plugin install end-to-end.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs"
PASS=0; FAIL=0
note() { echo "  - $*"; }
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# Pick a writable directory for the test log (probe via [ -w ] to avoid
# noisy "Permission denied" leaks when /tmp is locked down).
LOG=""
for cand_dir in "$HOME" "${TMPDIR:-/tmp}" "."; do
  if [ -d "$cand_dir" ] && [ -w "$cand_dir" ]; then
    LOG="$cand_dir/sidecar-test.log"
    break
  fi
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
[ -f "$PROXY_ENTRY" ] && pass "bundled proxy installed" || fail "bundled proxy missing at $PROXY_ENTRY"
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
# max_tokens=200, not 20: reasoning models (Gemini 3.1 Pro Preview, GPT-5.5, etc.)
# burn 80-90 tokens of internal chain-of-thought BEFORE emitting any visible
# text. With a budget below ~100, the model hits max_tokens during reasoning
# and returns content:null with stop_reason:max_tokens. The proxy's PATCH B3
# correctly produces content:[] in that case — but the test then misreads the
# empty content as a proxy bug. 200 gives a safe margin for any current model.
RESP=$(curl -sS "http://127.0.0.1:$PORT/v1/messages" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"client-sent-anything","max_tokens":200,"messages":[{"role":"user","content":"say ok"}]}')
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
echo "=== second request after first (catches Bug B1 — proxy must survive) ==="
# max_tokens=200 same reasoning as the first probe — reasoning models need
# headroom past their internal chain-of-thought before visible content lands.
RESP2=$(curl -sS "http://127.0.0.1:$PORT/v1/messages" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{"model":"x","max_tokens":200,"messages":[{"role":"user","content":"reply with one word"}]}')
TEXT2=$(echo "$RESP2" | python3 -c "import json,sys; print(json.load(sys.stdin).get('content',[{}])[0].get('text','?'))" 2>/dev/null || echo "?")
note "second-call text: $TEXT2"
[ -n "$TEXT2" ] && [ "$TEXT2" != "?" ] && pass "proxy answered a second request" || fail "second request failed (B1 regression?)"

echo
echo "=== two-turn tool-use round trip (catches C1 — tool_calls shape) ==="
# Replays an Anthropic-shaped multi-turn conversation that includes an
# assistant tool_use and a user tool_result. Strict providers (DeepSeek,
# OpenAI/GPT) reject malformed tool_calls schemas — Gemini's adapter
# accepts either form, which is why this slipped past earlier text-only tests.
TOOL_RESP=$(curl -sS "http://127.0.0.1:$PORT/v1/messages" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{
    "model": "x",
    "max_tokens": 200,
    "messages": [
      {"role": "user", "content": "What is 2+2?"},
      {"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_test_c1", "name": "calc", "input": {"expr": "2+2"}}
      ]},
      {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_test_c1", "content": "4"}
      ]}
    ]
  }')
if echo "$TOOL_RESP" | grep -q '"error"'; then
  fail "tool-use round trip rejected by upstream — ${TOOL_RESP:0:200}"
else
  pass "tool-use round trip accepted"
fi

echo
echo "=== mixed user content (text + tool_result) round trip (catches C2 — ordering) ==="
# Claude CLI sends tool_result + system-reminder text in a single user turn.
# OpenAI requires the tool message to be adjacent to the prior assistant
# tool_calls — interleaving user text breaks adjacency. This case must succeed
# against strict providers, not just Gemini.
MIXED_RESP=$(curl -sS "http://127.0.0.1:$PORT/v1/messages" \
  -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  -d '{
    "model": "x",
    "max_tokens": 200,
    "messages": [
      {"role": "user", "content": "What files are in /tmp?"},
      {"role": "assistant", "content": [
        {"type": "text", "text": "Let me check."},
        {"type": "tool_use", "id": "toolu_test_c2", "name": "bash", "input": {"command": "ls /tmp"}}
      ]},
      {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_test_c2", "content": "file1.txt"},
        {"type": "text", "text": "<system-reminder>respond concisely</system-reminder>"}
      ]}
    ]
  }')
if echo "$MIXED_RESP" | grep -q '"error"'; then
  fail "mixed text+tool_result rejected — ${MIXED_RESP:0:200}"
else
  pass "mixed user content (text + tool_result) round trip accepted"
fi

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
