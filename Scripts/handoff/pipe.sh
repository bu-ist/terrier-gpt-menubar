#!/bin/zsh
# Minimal end-to-end check: hand a handoff to Claude or Grok headless, outside the app.
# The app's recipes (run.sh) do this properly; this is for poking at one agent by hand.
#   ./url.sh kb-gap-verdict | ./pipe.sh claude
#   ./pipe.sh grok "Summarise these candidates in Spanish" < latest.json
# Read-only by design: no --always-approve / permission bypass, so nothing gets sent or published.
agent="${1:?usage: pipe.sh claude|grok [prompt]}"
prompt="${2:-You are receiving a TerrierGPT handoff envelope (JSON). Read its contract and payload. If it is a kb-gap-verdict, run the cts-orchestrate kb-desk-handoff chain on it. Otherwise summarise what it contains and what the next step would be. Do not send, publish, or submit anything.}"
envelope="$(cat)"
[[ -n "$envelope" ]] || { echo "No handoff on stdin." >&2; exit 1; }
case "$agent" in
  claude) exec claude -p "$prompt" --output-format json <<< "$envelope" ;;
  grok)   exec grok -p "$prompt"$'\n\n```json\n'"$envelope"$'\n```' --output-format json ;;
  *) echo "Unknown agent: $agent" >&2; exit 2 ;;
esac
