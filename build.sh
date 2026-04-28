#!/usr/bin/env bash
# build.sh — package this plugin source as a .plugin file ready for install.
#
# Steps:
#   1. Ensure node_modules is vendored under skills/sidecar/proxy/ (npm ci if missing)
#   2. Zip everything (excluding .git, .DS_Store, etc.) to a temp file
#   3. Copy to the parent ClaudeCowork directory as sidecar.plugin
#
# Run from the repo root. Idempotent.

set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_DIR="$DIR/skills/sidecar/proxy"
OUTNAME="sidecar.plugin"
OUTDIR="$(cd "$DIR/.." && pwd)"

echo "=== build sidecar plugin ==="
echo "  source: $DIR"
echo "  output: $OUTDIR/$OUTNAME"
echo

if [ ! -f "$PROXY_DIR/node_modules/anthropic-proxy/index.js" ]; then
  echo "vendoring proxy dependencies (npm ci)..."
  ( cd "$PROXY_DIR" && npm ci --omit=dev 2>&1 | tail -5 )
else
  echo "proxy dependencies already vendored — skipping npm ci"
fi
echo

# Build to /tmp first (Mac mount blocks rm/mv); then copy out.
TMPZIP="${TMPDIR:-/tmp}/$OUTNAME"
rm -f "$TMPZIP"
echo "zipping..."
( cd "$DIR" && zip -qr "$TMPZIP" . \
    -x '.git/*' '.git' '*.DS_Store' '.DS_Store' "$OUTNAME" 'build/*' 'dist/*' )

if [ ! -f "$TMPZIP" ]; then
  echo "error: zip did not produce $TMPZIP" >&2
  exit 1
fi

# Move into ClaudeCowork/ alongside the plugin source repo.
# Note: cannot rm the destination on the mount, so write through redirect-truncate-style
# approach by using cp -f (overwrites without unlinking).
cp -f "$TMPZIP" "$OUTDIR/$OUTNAME"

echo
echo "built $OUTDIR/$OUTNAME ($(du -h "$OUTDIR/$OUTNAME" | cut -f1))"
echo
echo "Install in Cowork by importing this .plugin file."
