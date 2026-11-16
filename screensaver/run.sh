#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/HotBagScreensaver"
if ! command -v swiftc >/dev/null; then
  echo 'The graphics view needs Xcode Command Line Tools (swiftc). Use hot-bag screensaver --terminal.' >&2
  exit 1
fi
if [ ! -x "$BIN" ] || [ "$HERE/main.swift" -nt "$BIN" ] || [ "$HERE/Flock.swift" -nt "$BIN" ] || [ "$HERE/Breakfast.swift" -nt "$BIN" ]; then
  echo 'Building the flying toaster graphics view…' >&2
  swiftc -O -module-cache-path "${TMPDIR:-/tmp}/hot-bag-swift-cache" "$HERE/main.swift" "$HERE/Flock.swift" "$HERE/Breakfast.swift" -o "$BIN"
fi
exec "$BIN" "$HERE/assets" "$HERE/../hot-bag" "$@"
