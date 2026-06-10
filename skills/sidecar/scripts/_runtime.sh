#!/usr/bin/env bash
# _runtime.sh — sourced helpers shared by ask.sh and compare.sh.
#
# Provides:
#   find_workdir            — echo the first writable dir from $HOME, $TMPDIR, .
#   pick_port <base>        — echo a free TCP port near <base> (PID-spread probe)
#   boot_proxy <base> <log> — start the proxy on a free port; sets CHOSEN_PORT
#                             and PROXY_PID; re-picks on bind races (3 attempts)
#   resolve_model <word>    — echo the full slug for a vendor word via
#                             <state>/defaults.env; full slugs pass through
#
# Expects _locate.sh to have been sourced first (SIDECAR_PLUGIN_DIR,
# SIDECAR_STATE_DIR). Kept bash-3.2 compatible (macOS direct use).

# Pick a writable directory for logs/artifacts. $HOME is reliably writable in
# Cowork sandboxes; /tmp often isn't. Probe via [ -w ] so a read-only dir
# never produces a "Permission denied" stderr leak.
find_workdir() {
  local d
  for d in "$HOME" "${TMPDIR:-/tmp}" "."; do
    if [ -d "$d" ] && [ -w "$d" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  printf '%s\n' "$HOME"
}

# Free-port probe. The PID-derived offset spreads concurrent instances so
# they rarely contend for the same candidate; the linear scan handles
# residual collisions. Not atomic — boot_proxy detects lost bind races
# (proxy exits EADDRINUSE) and re-picks.
pick_port() {
  local base="$1" off cand i
  off=$(( $$ % 500 ))
  for i in $(seq 0 19); do
    cand=$(( base + off + i ))
    if ! (echo > "/dev/tcp/127.0.0.1/$cand") 2>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# boot_proxy <base-port> <logfile>
# Starts the proxy (start.sh) on a free port near <base-port>. On success
# sets CHOSEN_PORT and PROXY_PID. The readiness loop checks PID liveness
# BEFORE the TCP connect: if our proxy lost a bind race and died, the port
# may answer — but it would be someone else's proxy with a different model.
boot_proxy() {
  local base="$1" log="$2" i
  for _ in 1 2 3; do
    CHOSEN_PORT="$(pick_port "$base")" || {
      echo "boot_proxy: no free port near $base" >&2
      return 1
    }
    SIDECAR_PORT_OVERRIDE="$CHOSEN_PORT" \
      bash "$SIDECAR_PLUGIN_DIR/scripts/start.sh" >> "$log" 2>&1 &
    PROXY_PID=$!
    for i in $(seq 1 24); do
      if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        break  # proxy died (likely EADDRINUSE) — re-pick and retry
      fi
      if (echo > "/dev/tcp/127.0.0.1/$CHOSEN_PORT") 2>/dev/null; then
        return 0
      fi
      sleep 0.25
    done
    kill "$PROXY_PID" 2>/dev/null || true
  done
  echo "boot_proxy: proxy did not come up after 3 attempts — log at $log" >&2
  return 1
}

# resolve_model <slug-or-vendor>
# Full slugs (anything containing '/') pass through untouched. Bare vendor
# words resolve via SIDECAR_MODEL_<VENDOR> lines in <state>/defaults.env.
# grep+cut, not source: defaults.env is user-writable and sourcing it under
# set -a could clobber the environment.
resolve_model() {
  local word="$1" up line
  case "$word" in
    */*)
      printf '%s\n' "$word"
      return 0
      ;;
  esac
  up=$(printf '%s' "$word" | tr 'a-z-' 'A-Z_')
  line=$(grep -E "^SIDECAR_MODEL_${up}=" "$SIDECAR_STATE_DIR/defaults.env" 2>/dev/null | tail -1)
  if [ -z "$line" ]; then
    echo "sidecar: no model alias for '$word' in $SIDECAR_STATE_DIR/defaults.env" >&2
    echo "         Use a full slug (vendor/model), or map the alias with:" >&2
    echo "         bash $SIDECAR_PLUGIN_DIR/scripts/refresh-defaults.sh $word <slug>" >&2
    return 2
  fi
  printf '%s\n' "$line" | cut -d= -f2- | tr -d '"'
}
