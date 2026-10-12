#!/bin/sh
# Builds GameData/ (what the app embeds) from your own disc image and packs it for the
# private data repository. Writes GameData.lock (version + checksum, safe to commit).
#
#   scripts/make_game_data.sh "<path>/Naruto - Uzumaki Chronicles 2 (Europe).iso"
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ISO=${1:?usage: make_game_data.sh <disc.iso>}

swift build --package-path "$ROOT/Packages/UCKit" -c release --product uc-tool
TOOL="$ROOT/Packages/UCKit/.build/release/uc-tool"
rm -rf "$ROOT/GameData"
"$TOOL" pack "$ISO" "$ROOT/GameData"

FORMAT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["format"])' "$ROOT/GameData/manifest.json")
ASSET="GameData-v$FORMAT.tar"
mkdir -p "$ROOT/.build"
# Stable archive: fixed order, owner and mtime, so the same disc always gives the same checksum.
find "$ROOT/GameData" -exec touch -h -t 200801220000 {} +
(cd "$ROOT" && find GameData -type f | LC_ALL=C sort > .build/gamedata.list)
(cd "$ROOT" && tar -c -f ".build/$ASSET" --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname "" --gname "" -T .build/gamedata.list)
SHA=$(shasum -a 256 "$ROOT/.build/$ASSET" | cut -d' ' -f1)

cat > "$ROOT/GameData.lock" <<LOCK
# Embedded game data (private package; never committed). See scripts/fetch_game_data.sh.
NUC2_DATA_REPO=byescaleira/naruto-uzumaki-chronicles-2-data
NUC2_DATA_TAG=data-v$FORMAT
NUC2_DATA_ASSET=$ASSET
NUC2_DATA_SHA256=$SHA
LOCK
echo "packed .build/$ASSET ($SHA)"
