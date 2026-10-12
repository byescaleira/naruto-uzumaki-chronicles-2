#!/bin/sh
# Xcode Cloud: the game data is not in this public repository. Fetch the private package
# (secret environment variable NUC2_DATA_TOKEN in the workflow) before building.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
./scripts/fetch_game_data.sh
