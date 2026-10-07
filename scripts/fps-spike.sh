#!/bin/bash
# M0 FPS spike (spec §3 Overlay): can Metal HUD logging give us another process's FPS, live and cheaply?
# Sets the Metal HUD environment for GUI apps launched from now on, captures Metal log lines,
# samples the CPU cost of `log stream`, and clears the environment on exit (Ctrl-C).
set -uo pipefail
OUT="${1:-$HOME/fps-spike-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

launchctl setenv MTL_HUD_ENABLED 1
launchctl setenv MTL_HUD_LOG_ENABLED 1
cleanup() {
    launchctl unsetenv MTL_HUD_ENABLED
    launchctl unsetenv MTL_HUD_LOG_ENABLED
    kill "$LOGPID" "$CPUPID" 2>/dev/null
    echo "Metal HUD environment cleared. Output in $OUT"
}
trap cleanup EXIT

log stream --style ndjson --level debug \
    --predicate 'subsystem BEGINSWITH "com.apple.Metal" OR category CONTAINS[c] "hud"' \
    > "$OUT/metal.ndjson" &
LOGPID=$!
( while kill -0 "$LOGPID" 2>/dev/null; do
      echo "$(date +%T) $(ps -o %cpu= -p "$LOGPID")" >> "$OUT/logstream-cpu.txt"
      sleep 10
  done ) &
CPUPID=$!

echo "Capturing to $OUT. Now quit Steam completely and relaunch it (or launch the game/emulator) so it"
echo "inherits the environment. Play for about 60 s with the Metal HUD visible, then press Ctrl-C here."
wait "$LOGPID"
