#!/usr/bin/env bash
#
# Build and install (or uninstall) the hot-bag system screen saver.
#
#   ./screensaver/saver/install.sh              build + install HotBag.saver
#   ./screensaver/saver/install.sh uninstall    remove it
#   ./screensaver/saver/install.sh build <dir>  build only, into <dir>
#
# This is the flying-toaster flock as a real macOS screen saver bundle. macOS
# itself starts it, dismisses it on mouse or key input, and asks for the login
# password, which makes it an actual lock. The `hot-bag screensaver` command is
# only a window over an unlocked session.
#
# OPT-IN and separate from the core install.sh; the hot-bag CLI never depends
# on it. No sudo, and it changes no power or security settings: choosing the
# saver and requiring a password stay your decisions in System Settings.
#
# Zero third-party dependencies: compiled with the swiftc that ships with the
# Xcode Command Line Tools.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
HOTBAG="$(cd "$SRC/.." && pwd)/hot-bag"
NAME="HotBag"
DEST_DIR="$HOME/Library/Screen Savers"
DEST="$DEST_DIR/$NAME.saver"

ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
log()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

# build <dir>: assemble <dir>/HotBag.saver from the shared sources.
build() {
  local out="$1/$NAME.saver"
  if ! command -v swiftc >/dev/null 2>&1; then
    err "swiftc not found. Install the Xcode Command Line Tools:  xcode-select --install"
    exit 1
  fi
  rm -rf "$out"
  mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
  log "Compiling the screen saver bundle (swiftc)…"
  swiftc -O -parse-as-library -module-name HotBagSaver \
    -module-cache-path "${TMPDIR:-/tmp}/hot-bag-swift-cache" \
    -emit-library -Xlinker -bundle \
    "$HERE/HotBagSaverView.swift" "$SRC/ToastView.swift" "$SRC/Flock.swift" "$SRC/Breakfast.swift" \
    -o "$out/Contents/MacOS/$NAME"
  local asset
  for asset in flying-toaster.gif butter-dragon.gif empty-toaster.gif escaped-toast.png; do
    cp "$SRC/assets/$asset" "$out/Contents/Resources/"
  done
  # HotBagCLI lets the saver ask the CLI for run telemetry (best effort).
  cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.hot-bag.screensaver</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Hot Bag</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>HotBagSaverView</string>
  <key>HotBagCLI</key><string>$HOTBAG</string>
</dict>
</plist>
PLIST
  plutil -lint "$out/Contents/Info.plist" >/dev/null
  # Ad-hoc signature: required for the system host to load arm64 code.
  codesign --force --sign - "$out" 2>/dev/null
  ok "Built $out"
}

case "${1:-install}" in
  build)
    [ "$#" -eq 2 ] || { err "usage: install.sh build <dir>"; exit 2; }
    mkdir -p "$2"
    build "$(cd "$2" && pwd)"
    ;;
  uninstall)
    if [ -d "$DEST" ]; then
      rm -rf "$DEST"
      ok "Removed $DEST"
    else
      warn "Nothing to remove: $DEST is not installed."
    fi
    warn "If Hot Bag was your selected screen saver, pick another in System Settings → Screen Saver."
    ;;
  install)
    [ "$#" -le 1 ] || { err "usage: install.sh [install|uninstall|build <dir>]"; exit 2; }
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hot-bag-saver.XXXXXX")"
    trap 'rm -rf "$STAGE"' EXIT
    build "$STAGE"
    mkdir -p "$DEST_DIR"
    # Replace only our own bundle; other savers in the folder are untouched.
    rm -rf "$DEST"
    cp -R "$STAGE/$NAME.saver" "$DEST"
    ok "Installed $DEST"
    echo
    log "To use it as a lock screen:"
    echo "    1. System Settings → Screen Saver → choose \"Hot Bag\" (under Other)."
    echo "    2. System Settings → Lock Screen → \"Require password after screen saver"
    echo "       begins or display is turned off\" → Immediately."
    echo "    3. Lock Screen → \"Start Screen Saver when inactive\" → pick a time, or set a"
    echo "       hot corner (Desktop & Dock → Hot Corners → Start Screen Saver)."
    echo
    warn "During a hot-bag run, caffeinate holds off the idle timer, so start the saver with a hot corner."
    warn "If an older copy was already loaded, log out and back in to pick up this build."
    log "Remove it any time:  ./screensaver/saver/install.sh uninstall"
    ;;
  *)
    err "usage: install.sh [install|uninstall|build <dir>]"
    exit 2
    ;;
esac
