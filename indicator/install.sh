#!/usr/bin/env bash
#
# Install (or uninstall) the hot-bag menu-bar indicator.
#
#   ./indicator/install.sh            build + load the LaunchAgent
#   ./indicator/install.sh uninstall  unload + remove it
#
# The indicator is a tiny Swift menu-bar agent that shows 🔥 while hot-bag is
# actively holding the Mac awake (and ⚠️ if it's wedged). It's OPT-IN and fully
# separate from the core `install.sh` — the hot-bag CLI never depends on it.
#
# Zero third-party dependencies: compiled with the swiftc that ships with the
# Xcode Command Line Tools, launched by launchd. No SwiftBar/xbar, no Homebrew.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$REPO_DIR/.." && pwd)"
HOTBAG="$PROJECT_DIR/hot-bag"
BIN="$REPO_DIR/HotBagIndicator"
SRC="$REPO_DIR/HotBagIndicator.swift"
TEMPLATE="$REPO_DIR/com.hot-bag.indicator.plist.template"

LABEL="com.hot-bag.indicator"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
LOG="$HOME/.local/state/hot-bag/indicator.log"
POLL="${HOTBAG_POLL_SECS:-5}"

# gui/<uid> is the per-user launchd domain for GUI (menu-bar) agents.
DOMAIN="gui/$(id -u)"

ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
log()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; }

unload() {
  # bootout is the modern unload; fall back to legacy `unload` on older macOS.
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null || true
}

if [ "${1:-}" = "uninstall" ]; then
  log "Uninstalling the hot-bag indicator…"
  unload
  rm -f "$PLIST"
  ok "Unloaded and removed $PLIST"
  warn "The compiled binary at $BIN is left in place (it's part of the repo build)."
  exit 0
fi

# ── build ─────────────────────────────────────────────────────────────────────
if ! command -v swiftc >/dev/null 2>&1; then
  err "swiftc not found. Install the Xcode Command Line Tools:  xcode-select --install"
  exit 1
fi
log "Compiling the menu-bar agent (swiftc)…"
swiftc -O -o "$BIN" "$SRC"
ok "Built $BIN"

# ── render the plist from the template ─────────────────────────────────────────
mkdir -p "$AGENTS_DIR" "$(dirname "$LOG")"
log "Writing LaunchAgent → $PLIST"
sed -e "s|__BIN__|$BIN|g" \
    -e "s|__HOTBAG__|$HOTBAG|g" \
    -e "s|__POLL__|$POLL|g" \
    -e "s|__LOG__|$LOG|g" \
    "$TEMPLATE" > "$PLIST"

# ── (re)load ────────────────────────────────────────────────────────────────────
unload   # idempotent: drop any previous instance first so a re-run refreshes it
if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
  ok "Loaded via launchctl bootstrap"
else
  # Older macOS without bootstrap semantics.
  launchctl load "$PLIST" && ok "Loaded via launchctl load" || {
    err "Could not load the agent. Try:  launchctl load $PLIST"
    exit 1
  }
fi

echo
ok "Indicator installed. It runs at login and shows:"
echo "    🔥  while hot-bag is actively holding the Mac awake"
echo "    ⚠️   if hot-bag is wedged (run: hot-bag doctor)"
echo "    (nothing) when off"
echo
log "Start a run (hot-bag start) and watch the menu bar. Logs: $LOG"
log "Remove it any time:  ./indicator/install.sh uninstall"
