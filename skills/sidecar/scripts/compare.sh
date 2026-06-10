#!/usr/bin/env bash
# compare.sh — fork one prompt to several models in parallel, print labeled results.
#
# Usage:
#   bash compare.sh "<prompt>" <slug-or-vendor> <slug-or-vendor> [...]
#
# Each fork runs ask.sh --model <target> with its own proxy on its own port;
# results print as labeled sections in argument order. A failed fork shows
# its stderr tail without sinking the others. Exit 0 if at least one fork
# succeeded.
#
# Env passthrough: MAX_RUN_SECONDS bounds each fork (exported to children);
# SIDECAR_TOOLS applies per fork exactly as in ask.sh.
#
# Cowork note: parallel forks still share the bash tool's 45s ceiling —
# launch compare.sh with run_in_background: true and read via TaskOutput.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_locate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_runtime.sh"

if [ "$#" -lt 3 ]; then
  echo "usage: compare.sh \"<prompt>\" <model> <model> [...]   (at least two models)" >&2
  exit 1
fi
PROMPT="$1"
shift
if [ -z "${PROMPT// /}" ]; then
  echo "compare.sh: empty prompt" >&2
  exit 1
fi

export MAX_RUN_SECONDS="${MAX_RUN_SECONDS:-180}"

CMP_DIR="$(find_workdir)/sidecar-compare.$$"
mkdir -p "$CMP_DIR" || { echo "compare.sh: cannot create $CMP_DIR" >&2; exit 1; }

# Fork one ask.sh per target — each boots its own proxy on its own port
# (pick_port spreads by child PID; boot_proxy resolves residual races).
PIDS=() TARGETS=()
i=0
for target in "$@"; do
  bash "$SCRIPT_DIR/ask.sh" --model "$target" "$PROMPT" \
    > "$CMP_DIR/out.$i" 2> "$CMP_DIR/err.$i" &
  PIDS[i]=$!
  TARGETS[i]="$target"
  i=$((i + 1))
done
N=$i

# Collect and report in argument order. Failure detail goes to stdout on
# purpose — the comparison consumer should see which fork failed inline.
OK=0
i=0
while [ "$i" -lt "$N" ]; do
  RC=0
  wait "${PIDS[$i]}" || RC=$?
  if [ "$RC" -eq 0 ]; then
    OK=$((OK + 1))
    echo "=== ${TARGETS[$i]} ==="
    cat "$CMP_DIR/out.$i"
  else
    echo "=== ${TARGETS[$i]} (FAILED rc=$RC) ==="
    tail -15 "$CMP_DIR/err.$i"
  fi
  echo
  i=$((i + 1))
done
# CMP_DIR is left behind deliberately: sandbox $HOME is ephemeral, and
# no-unlink mounts make cleanup unreliable — don't fight it.

if [ "$OK" -eq 0 ]; then
  echo "compare.sh: all $N forks failed" >&2
  exit 1
fi
