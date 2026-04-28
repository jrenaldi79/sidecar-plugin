#!/usr/bin/env bash
# setup.sh — first-run configuration for Sidecar (plugin install).
#
# The plugin ships with anthropic-proxy bundled at proxy/bundle.cjs,
# so no npm install is needed. This script just creates a per-user state directory
# (default: <connected-folder>/.sidecar/) and seeds it with .env.local from the
# template. Idempotent.

set -u

# locate plugin + state dir
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"

ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
err()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }

echo "=== Sidecar setup ==="
echo "  plugin dir: $SIDECAR_PLUGIN_DIR"
echo "  state dir:  $SIDECAR_STATE_DIR"
echo

# Verify prerequisites available
echo "Checking prerequisites..."
missing=0
for cmd in node curl claude; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd: $(command -v "$cmd")"
  else
    err "$cmd: NOT FOUND"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  err "Missing required tools."
  exit 1
fi
echo

# Verify the plugin's vendored proxy is intact
if [ -f "$SIDECAR_PLUGIN_DIR/proxy/bundle.cjs" ]; then
  ok "bundled proxy at $SIDECAR_PLUGIN_DIR/proxy/bundle.cjs"
else
  err "bundled proxy missing at $SIDECAR_PLUGIN_DIR/proxy/bundle.cjs"
  err "Plugin install may be corrupt — reinstall the plugin."
  exit 1
fi
echo

# Create state directory if missing. State dir lives in the user's connected folder
# so it persists across sessions and is per-user (not shipped with the plugin).
if [ ! -d "$SIDECAR_STATE_DIR" ]; then
  # Make sure the parent of state dir exists and is writable
  PARENT="$(dirname "$SIDECAR_STATE_DIR")"
  if [ ! -d "$PARENT" ]; then
    err "$PARENT does not exist."
    AVAILABLE=$(ls -d "$HOME"/mnt/*/ 2>/dev/null \
      | grep -v -E '/(outputs|uploads|\..*)/$' || true)
    if [ -n "$AVAILABLE" ]; then
      err "Available connected folders:"
      printf '%s\n' "$AVAILABLE" | sed 's|^|    |' >&2
      err "Set SIDECAR_STATE_DIR=<one of those>/.sidecar and retry,"
      err "or rerun setup.sh after connecting the folder you want to use."
    else
      err "No connected folders detected. Connect a folder to Cowork first."
    fi
    exit 1
  fi
  if ! mkdir -p "$SIDECAR_STATE_DIR" 2>/dev/null; then
    err "cannot create $SIDECAR_STATE_DIR (parent not writable)"
    exit 1
  fi
  ok "created state dir at $SIDECAR_STATE_DIR"
else
  ok "state dir exists at $SIDECAR_STATE_DIR"
fi

# Seed .env.local from template if missing
ENV_FILE="$SIDECAR_STATE_DIR/.env.local"
TEMPLATE="$SIDECAR_PLUGIN_DIR/.env.local.template"

if [ -f "$ENV_FILE" ]; then
  ok ".env.local exists at $ENV_FILE (leaving untouched)"
else
  if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$ENV_FILE"
    ok "Created $ENV_FILE from template"
    warn "Edit $ENV_FILE and set OPENROUTER_API_KEY before starting."
  else
    err "template missing at $TEMPLATE — plugin may be corrupt"
    exit 1
  fi
fi
echo

echo "=== Setup complete ==="
cat <<EOF
Next steps:
  1. Open $ENV_FILE and set OPENROUTER_API_KEY to your key from
     https://openrouter.ai/keys (anything starting with sk-or-).
  2. (Optional) Pick a model:
       bash $SCRIPT_DIR/list-models.sh gemini   # search the catalog
       bash $SCRIPT_DIR/set-model.sh google/gemini-3-flash-preview
  3. Verify everything works:
       bash $SCRIPT_DIR/test.sh
  4. Send a prompt:
       bash $SCRIPT_DIR/ask.sh "your question here"
EOF
