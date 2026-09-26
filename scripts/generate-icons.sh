#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ICON_DIR="$ROOT/resources/icons"
ICONSET="$ICON_DIR/AppIcon.iconset"
MASTER="$ICON_DIR/AppIcon-1024.png"
STATUS_ICON="$ICON_DIR/StatusIconTemplate.pdf"

mkdir -p "$ICON_DIR"
rm -f "$ICON_DIR/StatusIconTemplate.png"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

xcrun swift "$ROOT/scripts/generate-icons.swift" "$MASTER" "$STATUS_ICON"

make_icon() {
  size=$1
  output=$2
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$output" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ICON_DIR/AppIcon.icns"
rm -rf "$ICONSET"

printf 'Generated %s and %s\n' "$ICON_DIR/AppIcon.icns" "$STATUS_ICON"
