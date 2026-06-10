#!/usr/bin/env bash
# check-file-sizes.sh — enforce the 300-line limit on staged source files.
# Exits 1 if any staged hand-written source file exceeds MAX_LINES.
# Vendored/generated proxy artifacts are exempt (upstream code we patch, not author).

set -u
MAX_LINES=300
FAILED=0

is_source() {
  case "$1" in
    *.sh|*.mjs|*.cjs|*.js) return 0 ;;
  esac
  return 1
}

is_exempt() {
  case "$1" in
    skills/sidecar/proxy/bundle*.cjs) return 0 ;;          # esbuild output
    skills/sidecar/proxy/anthropic-proxy-patched.mjs) return 0 ;;  # vendored upstream
    skills/sidecar/proxy/node_modules/*) return 0 ;;
  esac
  return 1
}

while IFS= read -r file; do
  [ -n "$file" ] || continue
  is_source "$file" || continue
  is_exempt "$file" && continue
  lines=$(git show ":$file" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${lines:-0}" -gt "$MAX_LINES" ]; then
    echo "BLOCKED: $file is $lines lines (limit: $MAX_LINES). Refactor before committing." >&2
    FAILED=1
  fi
done < <(git diff --cached --name-only --diff-filter=ACM)

exit "$FAILED"
