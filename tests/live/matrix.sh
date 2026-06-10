#!/usr/bin/env bash
# matrix.sh — Tier 2 LIVE verification against real OpenRouter.
# Costs real money (pennies). Needs a valid key in .env.local (via _locate.sh)
# or $OPENROUTER_API_KEY. Run manually before tagging a release.
#
# For each model (one per provider-strictness family) it boots the real proxy
# and runs 4 probes: completion, tool round-trip (C1), mixed turn (C2),
# streaming SSE shape. Then one claude-CLI pong on the first model.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
SCRIPTS="$REPO/skills/sidecar/scripts"
BUNDLE="$REPO/skills/sidecar/proxy/bundle.cjs"

# Strictness matrix: lenient (Gemini) / strict (DeepSeek) / strict+Responses-path (OpenAI).
# Verify slugs with list-models.sh if a probe 404s.
MODELS=(
  "google/gemini-3-flash-preview"
  "deepseek/deepseek-v3.2"
  "openai/gpt-4o-mini"
)

# Key: env override, else .env.local via _locate.sh.
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPTS/_locate.sh"
  if [ -f "$SIDECAR_STATE_DIR/.env.local" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SIDECAR_STATE_DIR/.env.local"
    set +a
  fi
fi
if [ -z "${OPENROUTER_API_KEY:-}" ] || [ "${OPENROUTER_API_KEY:0:6}" != "sk-or-" ]; then
  echo "error: no valid OPENROUTER_API_KEY (env or .env.local)" >&2; exit 1
fi

PASS=0; FAIL=0; GRID=""
probe() { # $1=label $2=expect-grep(optional) $3=json-payload  (uses $PORT $MODEL)
  local resp
  resp=$(curl -sS --max-time 90 "http://127.0.0.1:$PORT/v1/messages" \
    -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d "$3")
  if echo "$resp" | grep -q '"error"'; then
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  $1 — ${resp:0:160}\n"; return 1
  fi
  if [ -n "$2" ] && ! echo "$resp" | grep -q "$2"; then
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  $1 — missing '$2': ${resp:0:160}\n"; return 1
  fi
  PASS=$((PASS+1)); GRID="$GRID  PASS  $MODEL  $1\n"
}

with_timeout() { # $1=seconds, rest=command. GNU `timeout` is absent on stock macOS,
  # so fall back to a background watchdog (bash 3.2 / BSD safe).
  local secs="$1" cmd_pid watch_pid rc
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return
  fi
  "$@" &
  cmd_pid=$!
  ( sleep "$secs"; kill "$cmd_pid" 2>/dev/null ) &
  watch_pid=$!
  wait "$cmd_pid"; rc=$?
  kill "$watch_pid" 2>/dev/null
  return "$rc"
}

boot_proxy() { # uses $MODEL; sets $PORT $PROXY_PID; returns 1 on boot failure
  PORT=$(( ( RANDOM % 2000 ) + 33000 ))
  OPENROUTER_API_KEY="$OPENROUTER_API_KEY" COMPLETION_MODEL="$MODEL" REASONING_MODEL="$MODEL" \
    PORT="$PORT" node "$BUNDLE" >"/tmp/sidecar-matrix-$PORT.log" 2>&1 &
  PROXY_PID=$!
  for _ in $(seq 1 40); do (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0; sleep 0.25; done
  return 1
}

for MODEL in "${MODELS[@]}"; do
  echo "=== $MODEL ==="
  if ! boot_proxy; then
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  proxy-boot\n"; kill "$PROXY_PID" 2>/dev/null; continue
  fi

  # max_tokens=300: reasoning models burn ~100 tokens of CoT before visible text
  # (same lesson as test.sh's 200-token floor; 300 adds margin for newer models).
  probe "completion " '"type":"text"' \
    '{"model":"x","max_tokens":300,"messages":[{"role":"user","content":"say ok"}]}'

  probe "tool-rtrip " '' \
    '{"model":"x","max_tokens":300,"messages":[
      {"role":"user","content":"What is 2+2?"},
      {"role":"assistant","content":[{"type":"tool_use","id":"toolu_m1","name":"calc","input":{"expr":"2+2"}}]},
      {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_m1","content":"4"}]}]}'

  probe "mixed-turn " '' \
    '{"model":"x","max_tokens":300,"messages":[
      {"role":"user","content":"What files are in /tmp?"},
      {"role":"assistant","content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_m2","name":"bash","input":{"command":"ls /tmp"}}]},
      {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_m2","content":"file1.txt"},{"type":"text","text":"<system-reminder>be brief</system-reminder>"}]}]}'

  STREAM_RESP=$(curl -sS --max-time 90 "http://127.0.0.1:$PORT/v1/messages" \
    -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
    -d '{"model":"x","max_tokens":300,"stream":true,"messages":[{"role":"user","content":"say ok"}]}')
  if echo "$STREAM_RESP" | grep -q "event: message_start" && echo "$STREAM_RESP" | grep -q "event: message_stop"; then
    PASS=$((PASS+1)); GRID="$GRID  PASS  $MODEL  stream-sse \n"
  else
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  stream-sse — ${STREAM_RESP:0:160}\n"
  fi

  kill "$PROXY_PID" 2>/dev/null; wait "$PROXY_PID" 2>/dev/null
done

# One claude-CLI pong on the first model (full client-compat check).
if command -v claude >/dev/null 2>&1; then
  MODEL="${MODELS[0]}"
  if boot_proxy; then
    CLI_OUT=$(ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" ANTHROPIC_API_KEY="proxy-ignores-this" ANTHROPIC_AUTH_TOKEN="" \
      with_timeout 60 claude -p "Reply with one short sentence containing the word 'pong'." </dev/null 2>&1)
    if echo "$CLI_OUT" | grep -qi pong; then PASS=$((PASS+1)); GRID="$GRID  PASS  $MODEL  claude-cli \n"
    else FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  claude-cli — ${CLI_OUT:0:160}\n"; fi
    kill "$PROXY_PID" 2>/dev/null
  else
    FAIL=$((FAIL+1)); GRID="$GRID  FAIL  $MODEL  proxy-boot(cli)\n"; kill "$PROXY_PID" 2>/dev/null
  fi
else
  GRID="$GRID  SKIP  claude CLI not installed\n"
fi

echo; echo "=== live matrix results ==="; printf "%b" "$GRID"
echo; echo "PASS: $PASS  FAIL: $FAIL"
exit "$FAIL"
