#!/usr/bin/env bash
# Development only; ImageMagick builds the shipped asset. No runtime dependency.
set -euo pipefail
cd "$(dirname "$0")/../assets"
magick toaster-sheet.png -resize 1792x896! -crop 4x2@ +repage -filter point -resize 224x224 -fuzz 3% -transparent black -set dispose background -set delay 10 -loop 0 flying-toaster.gif
magick flying-toaster.gif -coalesce -filter point -resize 50% -set delay 10 -loop 0 flying-toaster-small.gif
magick butter-dragon-sheet.png -resize 1792x896! -crop 4x2@ +repage -filter point -resize 224x224 -fuzz 3% -transparent black -set dispose background -set delay 10 -loop 0 butter-dragon.gif
magick empty-toaster-sheet.png -resize 1792x896! -crop 4x2@ +repage -filter point -resize 224x224 -fuzz 3% -transparent black -set dispose background -set delay 10 -loop 0 empty-toaster.gif
magick escaped-toast-source.png -filter point -resize 128x128 -fuzz 3% -transparent black escaped-toast.png
