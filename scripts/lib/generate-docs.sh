#!/usr/bin/env bash
# generate-docs.sh — regenerate the AUTO:tree section of CLAUDE.md.
# Lists tracked files with descriptions pulled from each script's header comment.
# Write mode (default): update CLAUDE.md in place and `git add` it if changed.
# --check: exit 1 if the section is stale (used by pre-push / CI).

set -u
ROOT=$(git rev-parse --show-toplevel)
DOC="$ROOT/CLAUDE.md"
cd "$ROOT" || exit 1

grep -q '<!-- AUTO:tree -->' "$DOC" 2>/dev/null || { echo "generate-docs: no AUTO:tree markers in CLAUDE.md — nothing to do"; exit 0; }

# First header-comment line of a script (after shebang), minus a "name — " prefix.
describe() {
  case "$1" in
    *.sh|*.mjs|*.cjs)
      awk -v base="$(basename "$1")" '
        NR<=6 && (/^# / || /^\/\/ /) {
          sub(/^(# |\/\/ )/, "")
          sub("^" base " (—|-) ", "")
          if (length($0) > 0) { print substr($0, 1, 76); exit }
        }' "$1" ;;
  esac
}

build_tree() {
  echo '```'
  git ls-files \
    | grep -v -e '^\.claude/' -e '^\.gitignore$' -e '^[A-Za-z.-]*\.md$' -e 'package-lock\.json' \
    | while IFS= read -r f; do
        d=$(describe "$f")
        if [ -n "$d" ]; then
          printf '%-50s # %s\n' "$f" "$d"
        else
          echo "$f"
        fi
      done
  echo '```'
}

# Splice via sed (BSD awk rejects multi-line -v strings). Markers must each
# sit on their own line.
TMP=$(mktemp)
{
  sed -n '1,/<!-- AUTO:tree -->/p' "$DOC"
  build_tree
  sed -n '/<!-- \/AUTO:tree -->/,$p' "$DOC"
} > "$TMP"

# Refuse to proceed if the splice somehow shrank the doc to nothing.
if [ ! -s "$TMP" ]; then
  rm -f "$TMP"
  echo "generate-docs: splice produced empty output — aborting without touching CLAUDE.md" >&2
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  if cmp -s "$TMP" "$DOC"; then
    rm -f "$TMP"; exit 0
  fi
  rm -f "$TMP"
  echo "STALE: CLAUDE.md AUTO:tree is out of date — run: bash scripts/lib/generate-docs.sh" >&2
  exit 1
fi

if ! cmp -s "$TMP" "$DOC"; then
  cp "$TMP" "$DOC"
  git add "$DOC"
  echo "generate-docs: CLAUDE.md AUTO:tree regenerated and staged"
fi
rm -f "$TMP"
exit 0
