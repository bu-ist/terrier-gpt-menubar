#!/bin/zsh
# After Export TerrierGPT Answer as Handoff (contract=ticket-search-report),
# fill the HTML report from latest.json (or a path on stdin / $1).
set -euo pipefail
WG="${CTS_AI_WG_ROOT:-$HOME/Documents/GitHub/cts-ai-working-group}"
PY="$WG/docs/orchestration/examples/handoff-ticket-search.py"
LATEST="$HOME/Library/Application Support/TerrierGPTMenu/handoffs/latest.json"
file="${1:-}"
if [[ -z "$file" ]]; then
  if [[ ! -t 0 ]]; then
    # stdin may be the envelope JSON from the App Intent
    tmp="$(mktemp)"
    cat > "$tmp"
    file="$tmp"
  else
    file="$LATEST"
  fi
fi
[[ -f "$file" ]] || { echo "No handoff file at $file" >&2; exit 2; }
exec /usr/bin/python3 "$PY" --file "$file"
