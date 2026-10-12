#!/bin/sh
# Xcode Cloud: the game data is not in this public repository. It comes from the private
# GameDataPackage submodule, which Xcode Cloud clones with its own repository access (grant it
# access to byescaleira/naruto-uzumaki-chronicles-2-data once); no token is needed.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
git submodule update --init GameDataPackage
./scripts/fetch_game_data.sh
