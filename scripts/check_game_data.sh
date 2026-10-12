#!/bin/sh
# Xcode build phase: the app embeds GameData/ (from the private package) on every platform.
# Fail early with instructions instead of shipping an app without the game.
set -eu
if [ ! -f "$SRCROOT/GameData/manifest.json" ]; then
    echo "error: GameData/ is missing. Run scripts/fetch_game_data.sh (private package) or scripts/make_game_data.sh <your disc.iso>."
    exit 1
fi
