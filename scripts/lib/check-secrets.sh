#!/usr/bin/env bash
# check-secrets.sh — scan staged file content for hardcoded credentials.
# Exits 1 (blocking the commit) if any pattern matches a non-allowlisted file.
# Scans the STAGED blob (git show :path), not the working tree.

set -u

# pattern|description  (ERE — BSD grep on macOS has no -P)
PATTERNS=(
  'sk-or-[A-Za-z0-9_-]{3,}|OpenRouter API key'
  'sk-ant-[A-Za-z0-9_-]{3,}|Anthropic API key'
  'AKIA[0-9A-Z]{16}|AWS access key'
  'ghp_[A-Za-z0-9_]{10,}|GitHub personal access token'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----|Private key block'
)

# Paths skipped entirely (docs and vendored/generated artifacts).
is_allowlisted() {
  case "$1" in
    *.md|docs/*) return 0 ;;
    skills/sidecar/proxy/bundle*.cjs) return 0 ;;
    skills/sidecar/proxy/node_modules/*) return 0 ;;
    *package-lock.json) return 0 ;;
  esac
  return 1
}

FAILED=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  is_allowlisted "$file" && continue
  for entry in "${PATTERNS[@]}"; do
    regex="${entry%%|*}"
    desc="${entry##*|}"
    if git show ":$file" 2>/dev/null | grep -qE -e "$regex"; then
      echo "BLOCKED: $desc found in staged file: $file" >&2
      FAILED=1
    fi
  done
done < <(git diff --cached --name-only --diff-filter=ACM)

if [ "$FAILED" -eq 1 ]; then
  echo "" >&2
  echo "Remove the secret, then re-stage. Real keys belong in .env.local (never committed)." >&2
  exit 1
fi
exit 0
