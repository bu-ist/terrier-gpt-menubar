#!/bin/zsh
# Shared helper: waits until latest.json changes after $1 (an mtime), then prints it.
# Triggers that can't return a value (URL scheme, AppleScript) hand off through this file.
LATEST="$HOME/Library/Application Support/TerrierGPTMenu/handoffs/latest.json"
before="${1:-0}"
for _ in {1..30}; do
  now=$(stat -f %m "$LATEST" 2>/dev/null || echo 0)
  if (( now > before )); then cat "$LATEST"; exit 0; fi
  sleep 0.5
done
echo "No new handoff after 15s — check the toast in the TerrierGPT panel." >&2
exit 1
