#!/usr/bin/env bash
# Turn the generated source artwork into every standard macOS icon size.
set -euo pipefail

SOURCE="${1:?Usage: build-icon.sh <source.png> <output.icns>}"
OUTPUT="${2:?Usage: build-icon.sh <source.png> <output.icns>}"
[[ -f "$SOURCE" ]] || { echo "Missing icon source: $SOURCE" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo "App icon packaging requires macOS." >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ICONSET="$STAGING/WorkLog.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUTPUT"
