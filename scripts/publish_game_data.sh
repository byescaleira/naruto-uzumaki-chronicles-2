#!/bin/sh
# Uploads .build/GameData-v<N>.tar to the PRIVATE data repository as a release asset
# (uses the gh CLI account; the repository is created private if it doesn't exist).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/GameData.lock"
if ! gh repo view "$NUC2_DATA_REPO" >/dev/null 2>&1; then
    gh repo create "$NUC2_DATA_REPO" --private \
        --description "Private: game data packages embedded in naruto-uzumaki-chronicles-2 builds (owner's own disc)."
fi
VISIBILITY=$(gh repo view "$NUC2_DATA_REPO" --json visibility --jq .visibility)
[ "$VISIBILITY" = "PRIVATE" ] || { echo "error: $NUC2_DATA_REPO must be private (is $VISIBILITY)" >&2; exit 1; }
if gh release view "$NUC2_DATA_TAG" --repo "$NUC2_DATA_REPO" >/dev/null 2>&1; then
    gh release upload "$NUC2_DATA_TAG" "$ROOT/.build/$NUC2_DATA_ASSET" --repo "$NUC2_DATA_REPO" --clobber
else
    gh release create "$NUC2_DATA_TAG" "$ROOT/.build/$NUC2_DATA_ASSET" --repo "$NUC2_DATA_REPO" \
        --title "Game data $NUC2_DATA_TAG" --notes "sha256 $NUC2_DATA_SHA256"
fi
echo "published $NUC2_DATA_ASSET to $NUC2_DATA_REPO@$NUC2_DATA_TAG"
