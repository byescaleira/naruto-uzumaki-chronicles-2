#!/bin/sh
# Puts the private game data package into GameData/, verified against GameData.lock.
#
# 1. From the GameDataPackage submodule (the private data repository, in 90 MB parts): what
#    Xcode Cloud uses — it clones the submodule with its own repository access, no token.
# 2. Otherwise from the data repository's release, with NUC2_DATA_TOKEN or the gh CLI login.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/GameData.lock"
if [ -f "$ROOT/GameData/.sha256" ] && [ "$(cat "$ROOT/GameData/.sha256")" = "$NUC2_DATA_SHA256" ]; then
    echo "GameData is up to date ($NUC2_DATA_TAG)"
    exit 0
fi
install_package() {
    echo "$NUC2_DATA_SHA256  $1" | shasum -a 256 -c -
    rm -rf "$ROOT/GameData"
    tar -x -f "$1" -C "$ROOT"
    echo "$NUC2_DATA_SHA256" > "$ROOT/GameData/.sha256"
    rm -f "$1"
}

PARTS="$ROOT/GameDataPackage/package"
if [ -f "$PARTS/PACKAGE" ] && grep -q "^NUC2_DATA_SHA256=$NUC2_DATA_SHA256$" "$PARTS/PACKAGE"; then
    mkdir -p "$ROOT/.build"
    cat "$PARTS/$NUC2_DATA_ASSET".part-* > "$ROOT/.build/$NUC2_DATA_ASSET"
    install_package "$ROOT/.build/$NUC2_DATA_ASSET"
    echo "assembled GameData ($NUC2_DATA_TAG) from the GameDataPackage submodule"
    exit 0
fi

TOKEN=${NUC2_DATA_TOKEN:-$(gh auth token 2>/dev/null || true)}
[ -n "$TOKEN" ] || {
    echo "error: GameDataPackage submodule missing or out of date, and no NUC2_DATA_TOKEN / gh login to fetch $NUC2_DATA_REPO." >&2
    echo "error: run 'git submodule update --init GameDataPackage' (Xcode Cloud: grant access to $NUC2_DATA_REPO)." >&2
    exit 1
}

API="https://api.github.com/repos/$NUC2_DATA_REPO"
ASSET_ID=$(curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/releases/tags/$NUC2_DATA_TAG" |
    python3 -c 'import json,sys; print(next(a["id"] for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]))' "$NUC2_DATA_ASSET")
mkdir -p "$ROOT/.build"
curl -fsSL --show-error --retry 3 -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" \
    -o "$ROOT/.build/$NUC2_DATA_ASSET" "$API/releases/assets/$ASSET_ID"
install_package "$ROOT/.build/$NUC2_DATA_ASSET"
echo "fetched GameData ($NUC2_DATA_TAG) from the release"
