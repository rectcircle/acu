#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <version>\n' "$0" >&2
  exit 1
fi

VERSION=${1#v}
if ! printf '%s\n' "$VERSION" |
  grep -Eq '^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z.-]+)?$'; then
  printf 'Invalid version: %s\n' "$1" >&2
  exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT_BASE="ACU-${VERSION}-macos-universal"
ARCHIVE="$ROOT/build/$ARTIFACT_BASE.tar.gz"
PACKAGE="$ROOT/build/$ARTIFACT_BASE.pkg"
PACKAGE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/acu-package.XXXXXX")
trap 'rm -rf "$PACKAGE_TMP"' EXIT
STAGED_APP="$PACKAGE_TMP/ACU.app"

ACU_VERSION="$VERSION" \
  ACU_ARCHES="${ACU_ARCHES:-arm64 amd64}" \
  "$ROOT/scripts/build-app.sh"

rm -f "$ARCHIVE" "$ARCHIVE.sha256" "$PACKAGE" "$PACKAGE.sha256"
ditto --norsrc "$ROOT/build/ACU.app" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
tar -czf "$ARCHIVE" -C "$PACKAGE_TMP" ACU.app
pkgbuild \
  --component "$STAGED_APP" \
  --install-location /Applications \
  --identifier github.com.rectcircle.acu \
  --version "$VERSION" \
  "$PACKAGE"

(
  cd "$ROOT/build"
  shasum -a 256 "$ARTIFACT_BASE.tar.gz" >"$ARTIFACT_BASE.tar.gz.sha256"
  shasum -a 256 "$ARTIFACT_BASE.pkg" >"$ARTIFACT_BASE.pkg.sha256"
)

printf 'Packaged %s and %s\n' "$ARCHIVE" "$PACKAGE"
