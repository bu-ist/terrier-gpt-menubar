#!/bin/zsh
# Trigger (consumer side): react to every new handoff, whoever produced it. This is the shape
# the launchd WatchPaths job in phase 3 will take; run it in a terminal to see it fire.
#   ./watch.sh                         print each new handoff
#   ./watch.sh ./pipe.sh claude        send each one to Claude
DIR="$HOME/Library/Application Support/TerrierGPTMenu/handoffs"
mkdir -p "$DIR"
last=$(stat -f %m "$DIR/latest.json" 2>/dev/null || echo 0)
echo "Watching $DIR (Ctrl-C to stop)…" >&2
while sleep 1; do
  now=$(stat -f %m "$DIR/latest.json" 2>/dev/null || echo 0)
  (( now > last )) || continue
  last=$now
  if (( $# )); then "$@" < "$DIR/latest.json"; else echo "--- $(date '+%T')"; cat "$DIR/latest.json"; fi
done
