#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/ACU Shield Preview.app"
OUTPUT=${1:-"$ROOT/website/assets/shield-zh.png"}
LANGUAGE=${2:-zh-Hans}
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$(dirname -- "$OUTPUT")"
cp -R "$ROOT/resources/en.lproj" "$APP/Contents/Resources/"
cp -R "$ROOT/resources/zh-Hans.lproj" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>github.com.rectcircle.acu.shield-preview</string>
<key>CFBundleName</key><string>ACU Shield Preview</string>
<key>CFBundleExecutable</key><string>shield-preview</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
clang -fobjc-arc -fblocks -mmacosx-version-min=15.0 \
  -framework AppKit -framework ApplicationServices -framework AVFoundation \
  -framework Carbon -framework ColorSync -framework CoreGraphics \
  -framework CoreFoundation -framework IOBluetooth -framework IOKit \
  -framework LocalAuthentication -framework QuartzCore -framework ServiceManagement \
  "$ROOT/scripts/shield-preview.m" -o "$APP/Contents/MacOS/shield-preview"
"$APP/Contents/MacOS/shield-preview" "$OUTPUT" -AppleLanguages "($LANGUAGE)"
# To inspect the same rendering in a regular window:
# build/ACU\ Shield\ Preview.app/Contents/MacOS/shield-preview OUTPUT.png --show
