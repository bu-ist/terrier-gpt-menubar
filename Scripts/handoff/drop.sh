#!/bin/zsh
# Drop a handoff into the inbox, atomically, so the recipe that claims it runs on its own.
#   ./drop.sh handoff.json                   route by the file's contract
#   ./drop.sh handoff.json kb-desk-handoff   route to this recipe (it still needs "inbox": true)
#   some-agent --json | ./drop.sh -          from stdin
# Any agent can do the same: write to a dotfile or *.tmp in the inbox, then rename.
INBOX="$HOME/Library/Application Support/TerrierGPTMenu/handoffs/inbox"
src="${1:?usage: drop.sh <file.json|-> [recipe]}"
mkdir -p "$INBOX"
name="$(date -u +%Y-%m-%dT%H-%M-%SZ)-drop-$$.json"
tmp="$INBOX/.$name"
if [[ "$src" == "-" ]]; then cat > "$tmp"; else cp "$src" "$tmp"; fi
# plutil -lint accepts old-style plists (a bare word passes), so parse as real JSON.
osascript -l JavaScript -e 'function run(a){ JSON.parse($.NSString.stringWithContentsOfFileEncodingError(a[0], $.NSUTF8StringEncoding, null).js) }' "$tmp" >/dev/null 2>&1 \
  || { rm -f "$tmp"; echo "Not valid JSON: $src" >&2; exit 1; }
if [[ -n "$2" ]]; then plutil -replace recipe -string "$2" "$tmp" || { rm -f "$tmp"; exit 1; }; fi
mv "$tmp" "$INBOX/$name" && echo "$INBOX/$name"
