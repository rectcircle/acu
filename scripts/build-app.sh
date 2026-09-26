#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/ACU Helper.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/resources/icons/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/resources/icons/StatusIconTemplate.pdf" \
  "$RESOURCES/StatusIconTemplate.pdf"

CGO_ENABLED=1 GOOS=darwin go build \
  -trimpath \
  -o "$MACOS/acu-helper" \
  "$ROOT/cmd/acu-helper"

IDENTITY=${ACU_CODESIGN_IDENTITY:--}
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - \
    --requirements '=designated => identifier "github.com.rectcircle.acu-helper"' \
    "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi

printf 'Built %s\n' "$APP"
