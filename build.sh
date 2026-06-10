#!/usr/bin/env bash
# build.sh — package this plugin source as a .plugin file ready for install.
#
# Steps:
#   1. Ensure node_modules vendored under skills/sidecar/proxy/ (npm ci if missing)
#   2. Bundle anthropic-proxy + deps into a single proxy/bundle.cjs via esbuild.
#      This eliminates @-scoped paths and other node_modules content from the
#      shipped plugin (Cowork's plugin validator rejects @ in paths).
#   3. Zip everything except node_modules, .git, dotfiles for build, etc.
#   4. Copy the resulting sidecar.plugin to the parent ClaudeCowork directory.
#
# Run from the repo root. Idempotent.

set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_DIR="$DIR/skills/sidecar/proxy"
ENTRY="$PROXY_DIR/wrapper.mjs"   # was: node_modules/anthropic-proxy/index.js
                                 # wrapper.mjs sets a global undici dispatcher
                                 # before loading anthropic-proxy so fetch()
                                 # honors HTTP_PROXY/HTTPS_PROXY in sandboxes.
BUNDLE="$PROXY_DIR/bundle.cjs"
OUTNAME="sidecar.plugin"
OUTDIR="$(cd "$DIR/.." && pwd)"

echo "=== build sidecar plugin ==="
echo "  source: $DIR"
echo "  output: $OUTDIR/$OUTNAME"
echo

# 1. Vendor deps for bundling (dev-only — not shipped).
# Wrapper.mjs imports anthropic-proxy and undici from node_modules; both must
# be present locally for esbuild to resolve and bundle them.
DEPS_MARKER="$PROXY_DIR/node_modules/anthropic-proxy/index.js"
if [ ! -f "$DEPS_MARKER" ]; then
  echo "vendoring proxy dependencies (npm ci)..."
  ( cd "$PROXY_DIR" && npm ci 2>&1 | tail -5 )
else
  echo "proxy dependencies already vendored — skipping npm ci"
fi
echo

# 2. Bundle the proxy into a single CJS file.
echo "bundling proxy with esbuild..."
( cd "$PROXY_DIR" && npx --yes esbuild "$ENTRY" \
    --bundle --platform=node --target=node18 --format=cjs \
    --outfile=bundle.cjs --log-level=warning )
echo "  -> $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"
echo

# 3. Zip the plugin source EXCEPT node_modules + dev artifacts.
TMPZIP="${TMPDIR:-/tmp}/$OUTNAME"
rm -f "$TMPZIP"
echo "zipping..."
( cd "$DIR" && zip -qr "$TMPZIP" . \
    -x '.git/*' '.git' \
       '.claude/*' '.claude' \
       '*.DS_Store' '.DS_Store' \
       "$OUTNAME" 'build/*' 'dist/*' \
       'scripts/*' 'scripts' 'CLAUDE.md' '.checks-passed' \
       'skills/sidecar/proxy/node_modules/*' \
       'skills/sidecar/proxy/node_modules' \
       'tests/*' 'tests' \
       'docs/*' 'docs' \
       '*/test/*' '*/tests/*' \
       '* *' '*/* */*' \
)

if [ ! -f "$TMPZIP" ]; then
  echo "error: zip did not produce $TMPZIP" >&2
  exit 1
fi

# 4. Sanity-check: validate paths in archive.
BAD=$(unzip -Z1 "$TMPZIP" | grep -E '[^a-zA-Z0-9._/-]' || true)
if [ -n "$BAD" ]; then
  echo "warning: archive contains non-conservative path chars:" >&2
  echo "$BAD" | head -5 >&2
fi

# 5. Copy out.
cp -f "$TMPZIP" "$OUTDIR/$OUTNAME"

echo
echo "built $OUTDIR/$OUTNAME ($(du -h "$OUTDIR/$OUTNAME" | cut -f1), $(unzip -Z1 "$TMPZIP" | wc -l | tr -d ' ') entries)"
echo
echo "Install in Cowork by importing this .plugin file."
