#!/usr/bin/env bash
# Symlink hot-bag into ~/.local/bin.
# Re-run any time; it just refreshes the symlink to point at this repo.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/bin/hot-bag"
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO/hot-bag" "$DEST"
chmod +x "$REPO/hot-bag"
echo "✓ linked $DEST → $REPO/hot-bag"

# ~/.local/bin is on PATH by default on many setups, but not all macOS shells.
# Detect it explicitly so the user doesn't get a confusing "command not found".
case ":${PATH:-}:" in
  *":$HOME/.local/bin:"*)
    echo "  try: hot-bag status"
    ;;
  *)
    echo
    echo "⚠  ~/.local/bin is not on your PATH. Add this to ~/.zshrc (or ~/.bashrc):"
    echo
    echo '    export PATH="$HOME/.local/bin:$PATH"'
    echo
    echo "  Then open a new shell and try:  hot-bag status"
    ;;
esac
