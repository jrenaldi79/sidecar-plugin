#!/usr/bin/env bash
# start.sh — boot the Sidecar proxy.
#
# Per-call overrides (used by ask.sh/compare.sh, applied AFTER sourcing
# .env.local so they win without mutating state):
#   SIDECAR_PORT_OVERRIDE        — listen port for this proxy instance
#   SIDECAR_COMPLETION_OVERRIDE  — upstream model for this instance
#   SIDECAR_REASONING_OVERRIDE   — reasoning model for this instance

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
# Entry resolved by _locate.sh: SIDECAR_BUNDLE_OVERRIDE > bundle.cjs >
# bundle-min.cjs (the tracked fallback that makes git-clone installs work).
PROXY_ENTRY="$SIDECAR_PROXY_ENTRY"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "warning: $ENV_FILE not found — run setup.sh first" >&2
fi

# Apply per-call overrides after the env file so they take precedence.
if [ -n "${SIDECAR_PORT_OVERRIDE:-}" ]; then
  export PORT="$SIDECAR_PORT_OVERRIDE"
fi
if [ -n "${SIDECAR_COMPLETION_OVERRIDE:-}" ]; then
  export COMPLETION_MODEL="$SIDECAR_COMPLETION_OVERRIDE"
fi
if [ -n "${SIDECAR_REASONING_OVERRIDE:-}" ]; then
  export REASONING_MODEL="$SIDECAR_REASONING_OVERRIDE"
fi

if [ ! -f "$PROXY_ENTRY" ]; then
  echo "error: bundled proxy missing at $PROXY_ENTRY" >&2
  exit 1
fi

cd "$(dirname "$PROXY_ENTRY")"
exec node "$(basename "$PROXY_ENTRY")"
