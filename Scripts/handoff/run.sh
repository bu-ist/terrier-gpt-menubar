#!/bin/zsh
# Trigger a recipe chain through the URL scheme. The app always asks before running a chain
# started from a link, then shows progress in the panel.
#   ./run.sh kb-desk-handoff
#   ./run.sh claude-then-grok ~/path/to/handoff.json     # start from a file, not the page
# Waits for the run's run.json; prints the final envelope on success, the summary otherwise.
RUNS="$HOME/Library/Application Support/TerrierGPTMenu/runs"
recipe="${1:?usage: run.sh <recipe> [input.json]}"
url="terriergpt://run?recipe=$recipe"
[[ -n "$2" ]] && url+="&input=${2:A}"
marker=$(mktemp); trap 'rm -f "$marker"' EXIT
open -g "$url"
echo "Started $recipe — confirm in the dialog; progress is in the TerrierGPT panel." >&2
for _ in {1..1800}; do   # up to 30 min
  summary=$(find "$RUNS" -name run.json -newer "$marker" 2>/dev/null | head -1)
  if [[ -n "$summary" ]]; then
    output=$(plutil -extract output raw -o - "$summary" 2>/dev/null)
    if [[ "$(plutil -extract status raw -o - "$summary")" == succeeded && -f "$output" ]]; then
      cat "$output"; exit 0
    fi
    cat "$summary" >&2; exit 1
  fi
  sleep 1
done
echo "No result after 30 min; check $RUNS." >&2
exit 1
