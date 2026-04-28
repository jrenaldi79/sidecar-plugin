#!/usr/bin/env bash
# ask.sh — send one prompt to Sidecar's configured upstream model.
#
# Usage:
#   bash ask.sh "your prompt here"
#   echo "your prompt" | bash ask.sh
#
# Env overrides:
#   PORT            — defaults to .env.local value or 3000
#   MAX_RUN_SECONDS — hard timeout on claude -p (default 60)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs"

# Pick a writable log path
for cand in "${TMPDIR:-/tmp}/sidecar-ask.log" "$HOME/sidecar-ask.log" "./sidecar-ask.log"; do
  if : > "$cand" 2>/dev/null; then LOG="$cand"; break; fi
done
LOG="${LOG:-$HOME/sidecar-ask.log}"

if [ "$#" -ge 1 ]; then
  PROMPT="$1"
else
  PROMPT="$(cat)"
fi
if [ -z "${PROMPT// /}" ]; then
  echo "ask.sh: empty prompt" >&2
  exit 2
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "ask.sh: $ENV_FILE not found — run setup.sh first" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

if [ ! -f "$PROXY_ENTRY" ]; then
  echo "ask.sh: bundled proxy missing at $PROXY_ENTRY" >&2
  exit 1
fi

PORT="${PORT:-3000}"
MAX_RUN_SECONDS="${MAX_RUN_SECONDS:-60}"

# Best-effort transcript discovery
TRANSCRIPT="$(bash "$SCRIPT_DIR/find-transcript.sh" 2>/dev/null || true)"
TRANSCRIPT_DIR="$(bash "$SCRIPT_DIR/find-transcript.sh" --dir 2>/dev/null || true)"

# Boot proxy
bash "$SCRIPT_DIR/start.sh" > "$LOG" 2>&1 &
PROXY_PID=$!

UP=0
for i in $(seq 1 24); do
  if (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then UP=1; break; fi
  sleep 0.25
done
if [ "$UP" -ne 1 ]; then
  echo "ask.sh: proxy did not come up — log at $LOG" >&2
  kill "$PROXY_PID" 2>/dev/null
  exit 1
fi

CLAUDE_ARGS=( -p )
if [ -n "$TRANSCRIPT" ] && [ -n "$TRANSCRIPT_DIR" ]; then
  CLAUDE_ARGS+=( --add-dir "$TRANSCRIPT_DIR" )
  SYS_HINT="THE PARENT COWORK CONVERSATION TRANSCRIPT is at $TRANSCRIPT. This JSONL file IS the authoritative source for any question about 'this conversation', 'what we discussed', 'what was decided', 'earlier', 'just now', or anything referring to prior turns. Each line is one record. User messages: \`\"type\":\"queue-operation\",\"operation\":\"enqueue\"\` (the \`content\` field is the user's prompt). Assistant messages: \`\"type\":\"assistant\"\` (text is in \`message.content[*].text\`). If the question references the conversation, you MUST use Grep on this exact file path to find relevant lines, then Read narrow line ranges from THIS file — do not substitute CLAUDE.md, README.md, or any other source file as context for what was 'discussed'. If the user's question is purely self-contained (e.g. arithmetic, general knowledge), ignore the transcript entirely."
  CLAUDE_ARGS+=( --append-system-prompt "$SYS_HINT" )
fi

printf '%s' "$PROMPT" | \
  ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  ANTHROPIC_AUTH_TOKEN="" \
  timeout "$MAX_RUN_SECONDS" claude "${CLAUDE_ARGS[@]}"
RC=$?

kill "$PROXY_PID" 2>/dev/null

if [ "$RC" -ne 0 ]; then
  echo "" >&2
  echo "ask.sh: sub-Claude exited $RC. Proxy log tail:" >&2
  tail -5 "$LOG" >&2
fi
exit "$RC"
