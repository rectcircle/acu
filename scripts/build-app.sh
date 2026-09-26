#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/ACU.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ARCHES=${ACU_ARCHES:-$(go env GOARCH)}
DEPLOYMENT_TARGET=${ACU_MACOS_DEPLOYMENT_TARGET:-15.0}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/acu-build.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

if ! printf '%s\n' "$DEPLOYMENT_TARGET" |
  grep -Eq '^[0-9]+(\.[0-9]+){1,2}$'; then
  printf 'Invalid macOS deployment target: %s\n' "$DEPLOYMENT_TARGET" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/resources/icons/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/resources/icons/StatusIconTemplate.pdf" \
  "$RESOURCES/StatusIconTemplate.pdf"
cp -R "$ROOT/resources/en.lproj" "$RESOURCES/en.lproj"
cp -R "$ROOT/resources/zh-Hans.lproj" "$RESOURCES/zh-Hans.lproj"

if [ -n "${ACU_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c \
    "Set :CFBundleShortVersionString $ACU_VERSION" \
    "$CONTENTS/Info.plist"
fi
if [ -n "${ACU_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c \
    "Set :CFBundleVersion $ACU_BUILD_NUMBER" \
    "$CONTENTS/Info.plist"
fi

BINARIES=
for ARCH in $ARCHES; do
  case "$ARCH" in
    arm64)
      CLANG_ARCH=arm64
      ;;
    amd64)
      CLANG_ARCH=x86_64
      ;;
    *)
      printf 'Unsupported architecture: %s\n' "$ARCH" >&2
      exit 1
      ;;
  esac

  BINARY="$TMP/acu-$ARCH"
  CGO_ENABLED=1 \
    GOOS=darwin \
    GOARCH="$ARCH" \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    CGO_CFLAGS="-arch $CLANG_ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET -Werror=unguarded-availability-new" \
    CGO_LDFLAGS="-arch $CLANG_ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
    go build \
      -trimpath \
      -o "$BINARY" \
      "$ROOT/cmd/acu"
  BINARIES="$BINARIES $BINARY"
done

set -- $BINARIES
if [ "$#" -eq 1 ]; then
  cp "$1" "$MACOS/acu"
else
  lipo -create "$@" -output "$MACOS/acu"
fi

IDENTITY=${ACU_CODESIGN_IDENTITY:--}
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - \
    --requirements '=designated => identifier "github.com.rectcircle.acu"' \
    "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi

printf 'Built %s\n' "$APP"
