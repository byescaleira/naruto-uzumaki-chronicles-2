#!/bin/sh
# Downloads and verifies the private game data package into GameData/.
# Token: NUC2_DATA_TOKEN (Xcode Cloud secret: fine-grained, read-only Contents on the data
# repository) or, locally, the gh CLI login.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/GameData.lock"
if [ -f "$ROOT/GameData/.sha256" ] && [ "$(cat "$ROOT/GameData/.sha256")" = "$NUC2_DATA_SHA256" ]; then
    echo "GameData is up to date ($NUC2_DATA_TAG)"
    exit 0
fi
TOKEN=${NUC2_DATA_TOKEN:-$(gh auth token 2>/dev/null || true)}
[ -n "$TOKEN" ] || { echo "error: set NUC2_DATA_TOKEN (or log in with gh) to fetch $NUC2_DATA_REPO" >&2; exit 1; }

API="https://api.github.com/repos/$NUC2_DATA_REPO"
ASSET_ID=$(curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/releases/tags/$NUC2_DATA_TAG" |
    python3 -c 'import json,sys; print(next(a["id"] for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]))' "$NUC2_DATA_ASSET")
mkdir -p "$ROOT/.build"
curl -fsSL --show-error --retry 3 -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" \
    -o "$ROOT/.build/$NUC2_DATA_ASSET" "$API/releases/assets/$ASSET_ID"
echo "$NUC2_DATA_SHA256  $ROOT/.build/$NUC2_DATA_ASSET" | shasum -a 256 -c -
rm -rf "$ROOT/GameData"
tar -x -f "$ROOT/.build/$NUC2_DATA_ASSET" -C "$ROOT"
echo "$NUC2_DATA_SHA256" > "$ROOT/GameData/.sha256"
rm -f "$ROOT/.build/$NUC2_DATA_ASSET"
echo "fetched GameData ($NUC2_DATA_TAG)"
