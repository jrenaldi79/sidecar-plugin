#!/usr/bin/env bash
# ask.sh — send one prompt to an OpenRouter model as a Claude CLI subagent.
#
# Usage:  bash ask.sh [flags] "your prompt"     (or pipe the prompt via stdin)
#
# Flags:
#   --model <slug|vendor>  per-call override: full slug or a vendor word
#                          resolved via <state>/defaults.env; never mutates .env.local
#   --continue             resume the most recent sidecar session (same Cowork
#                          session only; same model unless --model also given)
#   --fold                 sub-Claude ends with a structured fold block
#   --full-tools           lift the read-only default (allows Bash/Edit/Write)
#   --add-dir <path>       extra readable dir for sub-Claude (repeatable)
#   --                     end of flags (for prompts starting with '-')
#
# Env: PORT (base port, probed upward — concurrent asks don't collide),
#      MAX_RUN_SECONDS (default 180), SIDECAR_VERBOSE=1 (live stderr),
#      SIDECAR_TOOLS=readonly|full.
#
# Output contract: first stdout line is always `[sidecar: <slug>]` — the
# authoritative routing record (models hallucinate their own identity).
#
# Cowork bash tool calls have a 45s ceiling regardless of MAX_RUN_SECONDS —
# for long calls use run_in_background: true + TaskOutput, or a terminal.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_runtime.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
PROXY_ENTRY="$SIDECAR_PROXY_ENTRY"
# Sessions live in sandbox $HOME, NOT the mounted state dir: the session
# JSONLs in $HOME/.claude/projects die with the Cowork session — so must this map.
SESSIONS_FILE="$HOME/.sidecar-sessions"

WORK_DIR="$(find_workdir)"
LOG="$WORK_DIR/sidecar-ask.$$.log"
SUB_ERR="$WORK_DIR/sidecar-ask.$$.err"
OUT_JSON="$WORK_DIR/sidecar-ask.$$.json"
META="$WORK_DIR/sidecar-ask.$$.meta"

# ---------------- flags ----------------
MODEL_ARG="" FOLD=0 CONTINUE=0 PROMPT=""
TOOLS_MODE="${SIDECAR_TOOLS:-readonly}"
EXTRA_DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --model)      MODEL_ARG="${2:?ask.sh: --model needs a slug or vendor word}"; shift 2 ;;
    --continue)   CONTINUE=1; shift ;;
    --fold)       FOLD=1; shift ;;
    --full-tools) TOOLS_MODE="full"; shift ;;
    --add-dir)    EXTRA_DIRS+=( "${2:?ask.sh: --add-dir needs a path}" ); shift 2 ;;
    --)           shift; if [ $# -ge 1 ]; then PROMPT="$1"; fi; break ;;
    -*)           echo "ask.sh: unknown flag $1 (see the header of this script)" >&2; exit 2 ;;
    *)            PROMPT="$1"; shift ;;
  esac
done
if [ -z "$PROMPT" ] && [ ! -t 0 ]; then
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
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ ! -f "$PROXY_ENTRY" ]; then
  echo "ask.sh: bundled proxy missing at $PROXY_ENTRY" >&2
  exit 1
fi

# ---------------- session resume ----------------
RESUME_SID="" RESUME_SLUG="" RESUME_CWD=""
if [ "$CONTINUE" -eq 1 ]; then
  if [ ! -s "$SESSIONS_FILE" ]; then
    echo "ask.sh: --continue but no prior session recorded in $SESSIONS_FILE" >&2
    echo "        (sessions only survive within one Cowork session's sandbox)" >&2
    exit 1
  fi
  IFS=$'\t' read -r _ RESUME_SID RESUME_SLUG RESUME_CWD <<< "$(tail -1 "$SESSIONS_FILE")"
  if [ -z "$RESUME_SID" ]; then
    echo "ask.sh: malformed $SESSIONS_FILE — cannot --continue" >&2
    exit 1
  fi
  # claude looks sessions up per project directory — restore the cwd the
  # session was started from.
  if [ -n "$RESUME_CWD" ] && [ -d "$RESUME_CWD" ]; then
    cd "$RESUME_CWD" || true
  fi
fi

# ---------------- model resolution ----------------
# Priority: --model > --continue's stored slug > .env.local COMPLETION_MODEL.
RESOLVED_SLUG="${COMPLETION_MODEL:-}"
if [ -n "$MODEL_ARG" ]; then
  RESOLVED_SLUG="$(resolve_model "$MODEL_ARG")" || exit 2
elif [ "$CONTINUE" -eq 1 ] && [ -n "$RESUME_SLUG" ]; then
  RESOLVED_SLUG="$RESUME_SLUG"
fi
if [ -z "$RESOLVED_SLUG" ]; then
  echo "ask.sh: no model configured (COMPLETION_MODEL unset and no --model)" >&2
  exit 1
fi
if [ "$RESOLVED_SLUG" != "${COMPLETION_MODEL:-}" ]; then
  export SIDECAR_COMPLETION_OVERRIDE="$RESOLVED_SLUG"
  export SIDECAR_REASONING_OVERRIDE="$RESOLVED_SLUG"
fi

# ---------------- proxy boot ----------------
BASE_PORT="${PORT:-3000}"
# 180s default: reasoning + tool-use chains routinely exceed 60s. The proxy
# has its own 120s upstream-fetch timeout (anthropic-proxy-patched.mjs P2).
MAX_RUN_SECONDS="${MAX_RUN_SECONDS:-180}"
# timeout(1) is GNU coreutils — in the Linux sandbox always, on stock macOS
# often not. Degrade to no wall-clock guard rather than failing outright.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=( timeout --foreground "$MAX_RUN_SECONDS" )
else
  echo "ask.sh: timeout(1) not found — running without the ${MAX_RUN_SECONDS}s guard" >&2
fi

boot_proxy "$BASE_PORT" "$LOG" || exit 1
# The CLI must target the port we actually bound — never the .env.local
# ANTHROPIC_BASE_URL, which assumes the fixed default port.
BASE_URL="http://127.0.0.1:$CHOSEN_PORT"

# ---------------- sub-Claude arguments ----------------
TRANSCRIPT="$(bash "$SCRIPT_DIR/find-transcript.sh" 2>/dev/null || true)"
TRANSCRIPT_DIR="$(bash "$SCRIPT_DIR/find-transcript.sh" --dir 2>/dev/null || true)"

CLAUDE_ARGS=( -p --output-format json )
if [ "$CONTINUE" -eq 1 ]; then
  CLAUDE_ARGS+=( --resume "$RESUME_SID" )
fi
# Read-only by default: a third-party model drives sub-Claude, so write and
# execute capabilities are opt-in (--full-tools / SIDECAR_TOOLS=full).
if [ "$TOOLS_MODE" != "full" ]; then
  CLAUDE_ARGS+=( --allowedTools "Read,Grep,Glob" \
                 --disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch" )
fi

SYS_HINT=""
if [ -n "$TRANSCRIPT" ] && [ -n "$TRANSCRIPT_DIR" ]; then
  CLAUDE_ARGS+=( --add-dir "$TRANSCRIPT_DIR" )
  SYS_HINT="THE PARENT COWORK CONVERSATION TRANSCRIPT is at $TRANSCRIPT. This JSONL file IS the authoritative source for any question about 'this conversation', 'what we discussed', 'what was decided', 'earlier', 'just now', or anything referring to prior turns. Each line is one record. User messages: \`\"type\":\"queue-operation\",\"operation\":\"enqueue\"\` (the \`content\` field is the user's prompt). Assistant messages: \`\"type\":\"assistant\"\` (text is in \`message.content[*].text\`). If the question references the conversation, you MUST use Grep on this exact file path to find relevant lines, then Read narrow line ranges from THIS file — do not substitute CLAUDE.md, README.md, or any other source file as context for what was 'discussed'. If the user's question is purely self-contained (e.g. arithmetic, general knowledge), ignore the transcript entirely."
fi
# ${arr[@]+...} keeps set -u happy on empty arrays under bash 3.2 (macOS).
for d in ${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}; do
  CLAUDE_ARGS+=( --add-dir "$d" )
done
if [ "$FOLD" -eq 1 ]; then
  FOLD_HINT="End your reply with a fold block in exactly this shape:
--- FOLD ---
Answer: <one sentence> / Key evidence: <the 1-3 facts it rests on> / Confidence: <high|medium|low> / Consulted: <transcript | files | none>"
  SYS_HINT="${SYS_HINT:+$SYS_HINT

}$FOLD_HINT"
fi
if [ -n "$SYS_HINT" ]; then
  CLAUDE_ARGS+=( --append-system-prompt "$SYS_HINT" )
fi

# ---------------- run ----------------
# Sub-Claude stderr goes to a separate file so we can show it on failure
# without contaminating the success-path stdout that callers consume.
: > "$SUB_ERR" 2>/dev/null

run_subclaude() {
  if [ "${SIDECAR_VERBOSE:-0}" = "1" ]; then
    printf '%s' "$PROMPT" | \
      ANTHROPIC_BASE_URL="$BASE_URL" \
      ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-proxy-ignores-this}" \
      ANTHROPIC_AUTH_TOKEN="" \
      ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude "${CLAUDE_ARGS[@]}" \
      > "$OUT_JSON" 2> >(tee -a "$SUB_ERR" >&2)
  else
    printf '%s' "$PROMPT" | \
      ANTHROPIC_BASE_URL="$BASE_URL" \
      ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-proxy-ignores-this}" \
      ANTHROPIC_AUTH_TOKEN="" \
      ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude "${CLAUDE_ARGS[@]}" \
      > "$OUT_JSON" 2>> "$SUB_ERR"
  fi
}

START_TS=$SECONDS
run_subclaude
RC=$?
# Known failure shape: anthropic-proxy occasionally dies on a partial JSON
# chunk from OpenRouter. If sub-Claude failed AND the proxy is gone, restart
# the proxy and retry exactly once.
if [ "$RC" -ne 0 ] && ! kill -0 "$PROXY_PID" 2>/dev/null; then
  echo "ask.sh: proxy died mid-call — restarting and retrying once" >&2
  if boot_proxy "$BASE_PORT" "$LOG"; then
    BASE_URL="http://127.0.0.1:$CHOSEN_PORT"
    run_subclaude
    RC=$?
  fi
fi
DURATION=$(( SECONDS - START_TS ))

# wait reaps the job quietly — without it bash prints "Terminated" to stderr.
{ kill "$PROXY_PID" && wait "$PROXY_PID"; } 2>/dev/null

# ---------------- output + bookkeeping ----------------
parse_result() {
  python3 - "$OUT_JSON" "$META" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(3)
if not isinstance(d, dict) or "result" not in d:
    sys.exit(3)
text = d.get("result") or ""
sys.stdout.write(text if text.endswith("\n") or not text else text + "\n")
u = d.get("usage") or {}
with open(sys.argv[2], "w") as m:
    m.write("%s\t%s\t%s\n" % (d.get("session_id", ""),
                              u.get("input_tokens", ""),
                              u.get("output_tokens", "")))
PY
}

# Authoritative routing record, from config — models hallucinate their identity.
printf '[sidecar: %s]\n' "$RESOLVED_SLUG"
PARSED=0
if [ -s "$OUT_JSON" ] && parse_result; then
  PARSED=1
else
  # Non-JSON output (older CLI, hard crash mid-stream): never lose the
  # answer — emit it raw and skip session/token bookkeeping.
  cat "$OUT_JSON" 2>/dev/null
fi

SID="" IN_TOK="" OUT_TOK=""
if [ "$PARSED" -eq 1 ] && [ -s "$META" ]; then
  SID="$(cut -f1 < "$META")"
  IN_TOK="$(cut -f2 < "$META")"
  OUT_TOK="$(cut -f3 < "$META")"
fi
if [ -n "$SID" ]; then
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$SID" "$RESOLVED_SLUG" "$PWD" \
    >> "$SESSIONS_FILE" 2>/dev/null || true
fi
# One history line per run, failures included (append keeps the inode —
# safe on no-unlink mounts).
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RESOLVED_SLUG" "$DURATION" "$RC" \
  "${IN_TOK:-?}" "${OUT_TOK:-?}" \
  >> "$SIDECAR_STATE_DIR/history.log" 2>/dev/null || true

# ---------------- failure diagnosis ----------------
if [ "$RC" -ne 0 ]; then
  echo "" >&2
  case "$RC" in
    124)
      echo "ask.sh: sub-Claude hit MAX_RUN_SECONDS=${MAX_RUN_SECONDS}s timeout." >&2
      echo "       To extend: MAX_RUN_SECONDS=300 bash ask.sh \"<prompt>\"" >&2
      echo "       (If invoked from a Cowork bash tool, that tool's own 45s ceiling" >&2
      echo "        applies regardless — use run_in_background or a terminal.)" >&2
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
  echo "  • Stale vendor alias     → bash <SKILL>/scripts/refresh-defaults.sh <vendor> <slug>" >&2
  echo "  • Needs Bash/Edit/Write  → rerun with --full-tools" >&2
  echo "  • Hung mid-call          → SIDECAR_VERBOSE=1 bash ask.sh \"…\" to see live progress" >&2
fi
exit "$RC"
