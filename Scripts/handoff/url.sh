#!/bin/zsh
# Trigger: URL scheme. Same thing Raycast, a Shortcut "Open URL", or any launcher would do.
#   ./url.sh                   newest JSON block
#   ./url.sh kb-gap-verdict    only that contract
LATEST="$HOME/Library/Application Support/TerrierGPTMenu/handoffs/latest.json"
before=$(stat -f %m "$LATEST" 2>/dev/null || echo 0)
sleep 1   # mtime has 1s resolution; make sure the new file is strictly newer
open -g "terriergpt://handoff${1:+?contract=$1}"
exec "${0:A:h}/_wait-latest.sh" "$before"
