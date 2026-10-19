#!/bin/sh
# Builds TerrierGPT Companion for Safari into the app extension. Xcode runs this
# as the "Build web extension" phase of the TerrierGPT Companion target, so the
# extension always matches ../terrier-gpt-companion: change the companion, press
# Run, and Safari has the change. Nothing is copied into this repo.
#
# Needs Node and the companion checked out next to this repo (as DropDoc is).
# TERRIERGPT_COMPANION_DIR overrides where the companion lives.
set -eu

COMPANION="${TERRIERGPT_COMPANION_DIR:-${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/../terrier-gpt-companion}"
OUT="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

# Xcode does not inherit the login shell's PATH.
NODE="$(command -v node || true)"
for candidate in /opt/homebrew/bin/node /usr/local/bin/node; do
  [ -n "$NODE" ] && break
  [ -x "$candidate" ] && NODE="$candidate"
done

if [ ! -f "$COMPANION/tools/build.mjs" ]; then
  echo "error: TerrierGPT Companion not found at $COMPANION. Clone bu-ist/terrier-gpt-companion next to this repo, or set TERRIERGPT_COMPANION_DIR."
  exit 1
fi
if [ -z "$NODE" ]; then
  echo "error: Node is needed to build the Safari extension (brew install node)."
  exit 1
fi

# The Safari tests are fast and catch a worker that would die on load.
if ! "$NODE" "$COMPANION/tools/test-safari.mjs" > "${DERIVED_FILE_DIR:-/tmp}/test-safari.log" 2>&1; then
  grep FAIL "${DERIVED_FILE_DIR:-/tmp}/test-safari.log" | sed 's/^/error: Safari build check: /'
  exit 1
fi

"$NODE" "$COMPANION/tools/build.mjs" safari --out "$OUT"
REV="$(git -C "$COMPANION" describe --always --dirty 2>/dev/null || echo unknown)"
echo "TerrierGPT Companion $REV built into $OUT"
