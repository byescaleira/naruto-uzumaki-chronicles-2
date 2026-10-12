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

# The same package as git content in the GameDataPackage submodule (90 MB parts, under GitHub's
# 100 MB file limit), so Xcode Cloud gets it with its own repository access.
SUB="$ROOT/GameDataPackage"
if [ -d "$SUB/.git" ] || [ -f "$SUB/.git" ]; then
    rm -rf "$SUB/package"
    mkdir -p "$SUB/package"
    split -b 90m -a 2 "$ROOT/.build/$NUC2_DATA_ASSET" "$SUB/package/$NUC2_DATA_ASSET.part-"
    printf 'NUC2_DATA_TAG=%s\nNUC2_DATA_ASSET=%s\nNUC2_DATA_SHA256=%s\n' "$NUC2_DATA_TAG" "$NUC2_DATA_ASSET" "$NUC2_DATA_SHA256" > "$SUB/package/PACKAGE"
    git -C "$SUB" add -A package
    git -C "$SUB" commit -q -m "Game data package $NUC2_DATA_TAG in 90 MB parts"
    git -C "$SUB" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q origin HEAD:main
    echo "updated the GameDataPackage submodule; commit the new submodule pointer in this repository"
fi
