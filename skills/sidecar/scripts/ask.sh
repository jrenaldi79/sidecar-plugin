#!/usr/bin/env bash
# ask.sh — send one prompt to Sidecar's configured upstream model.
#
# Usage:
#   bash ask.sh "your prompt here"
#   echo "your prompt" | bash ask.sh
#
# Env overrides:
#   PORT            — defaults to .env.local value or 3000
#   MAX_RUN_SECONDS — hard timeout on claude -p (default 180; bump for
#                     long reasoning + tool-use chains)
#   SIDECAR_VERBOSE — '1' to mirror sub-Claude stderr live for progress
#                     visibility (otherwise silent until completion)
#
# IMPORTANT: when invoked from inside a Cowork bash tool, that tool has
# its own 45s ceiling. ask.sh's MAX_RUN_SECONDS can be larger but the
# bash tool will kill the whole bash invocation at 45s regardless. For
# long-running calls, run ask.sh from a real terminal or break the work
# into smaller prompts.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
PROXY_ENTRY="$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs"

# Pick a writable directory for the proxy log. $HOME is reliably writable in
# Cowork sandboxes; /tmp often isn't. Probe writability via [ -w ] so a
# read-only dir never produces a "Permission denied" stderr leak.
LOG=""
for cand_dir in "$HOME" "${TMPDIR:-/tmp}" "."; do
  if [ -d "$cand_dir" ] && [ -w "$cand_dir" ]; then
    LOG="$cand_dir/sidecar-ask.log"
    break
  fi
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
# Default raised from 60→180. Reasoning models + tool-use chains routinely
# exceed 60s. The hard wall-clock is OK to bump; the proxy itself has its
# own 120s upstream-fetch timeout (see anthropic-proxy-patched.mjs P2).
MAX_RUN_SECONDS="${MAX_RUN_SECONDS:-180}"

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

# Sub-Claude stderr goes to a separate file so we can show it on failure
# without contaminating the success-path stdout that callers consume.
SUB_ERR=""
for cand_dir in "$HOME" "${TMPDIR:-/tmp}" "."; do
  if [ -d "$cand_dir" ] && [ -w "$cand_dir" ]; then
    SUB_ERR="$cand_dir/sidecar-ask.err"; break
  fi
done
SUB_ERR="${SUB_ERR:-$HOME/sidecar-ask.err}"
: > "$SUB_ERR" 2>/dev/null

if [ "${SIDECAR_VERBOSE:-0}" = "1" ]; then
  # Mirror stderr live AND save it. tee runs in the foreground but the
  # underlying claude pipeline still drives the whole call.
  printf '%s' "$PROMPT" | \
    ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
    ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    ANTHROPIC_AUTH_TOKEN="" \
    timeout --foreground "$MAX_RUN_SECONDS" claude "${CLAUDE_ARGS[@]}" 2> >(tee "$SUB_ERR" >&2)
  RC=$?
else
  printf '%s' "$PROMPT" | \
    ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL" \
    ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    ANTHROPIC_AUTH_TOKEN="" \
    timeout --foreground "$MAX_RUN_SECONDS" claude "${CLAUDE_ARGS[@]}" 2> "$SUB_ERR"
  RC=$?
fi

kill "$PROXY_PID" 2>/dev/null

if [ "$RC" -ne 0 ]; then
  echo "" >&2
  case "$RC" in
    124)
      echo "ask.sh: sub-Claude hit MAX_RUN_SECONDS=${MAX_RUN_SECONDS}s timeout." >&2
      echo "       To extend: MAX_RUN_SECONDS=300 bash ask.sh \"<prompt>\"" >&2
      echo "       (If invoked from a Cowork bash tool, that tool's own 45s ceiling" >&2
      echo "        applies regardless — run from a terminal or split the work.)" >&2
      ;;
    137)
      echo "ask.sh: sub-Claude was killed (SIGKILL) — likely the bash tool's own ceiling." >&2
      ;;
    *)
      echo "ask.sh: sub-Claude exited $RC." >&2
      ;;
  esac
  echo "" >&2
  echo "Proxy log tail (looking for upstream errors / hangs):" >&2
  tail -10 "$LOG" >&2
  if [ -s "$SUB_ERR" ]; then
    echo "" >&2
    echo "Sub-Claude stderr tail:" >&2
    tail -10 "$SUB_ERR" >&2
  fi
  echo "" >&2
  echo "Common fixes:" >&2
  echo "  • Long reasoning chain → MAX_RUN_SECONDS=300 …" >&2
  echo "  • Empty/null upstream    → check OPENROUTER_API_KEY + allow-list (Settings ▸ Capabilities)" >&2
  echo "  • Unknown model          → bash <SKILL>/scripts/list-models.sh <vendor>" >&2
  echo "  • Hung mid-call          → SIDECAR_VERBOSE=1 bash ask.sh \"…\" to see live progress" >&2
fi
exit "$RC"
