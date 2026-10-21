#!/usr/bin/env bash
# Compiles SafariWebExtensionHandler with a small driver and runs it against a
# throwaway support folder, so the Safari bridge is checked without Safari.
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/support"
# Top-level code is only allowed in a file named main.swift.
cp Scripts/tests/safari-handler-main.swift "$WORK/main.swift"
xcrun swiftc -O -o "$WORK/driver" \
  SafariExtension/Sources/SafariWebExtensionHandler.swift \
  "$WORK/main.swift" \
  -framework SafariServices -framework AppKit
TERRIERGPT_SUPPORT="$WORK/support" TERRIERGPT_ANNOUNCE_LOG="$WORK/announced.log" "$WORK/driver"
