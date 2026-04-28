#!/usr/bin/env bash
# stop.sh — kill any running Sidecar proxy.
# Pattern is specific (matches the Node entry path) so it doesn't accidentally
# kill the calling shell or unrelated node processes.

set -u

PIDS=$(pgrep -f "node.*node_modules/anthropic-proxy/index" 2>/dev/null || true)

if [ -z "$PIDS" ]; then
  echo "no Sidecar proxy running"
  exit 0
fi

echo "stopping Sidecar proxy (pids: $PIDS)"
kill $PIDS 2>/dev/null || true
sleep 0.5
PIDS=$(pgrep -f "node.*node_modules/anthropic-proxy/index" 2>/dev/null || true)
[ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null || true
echo "stopped"
