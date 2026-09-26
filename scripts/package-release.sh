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
ARCHIVE="$ROOT/build/ACU.tar.gz"

ACU_VERSION="$VERSION" \
  ACU_ARCHES="${ACU_ARCHES:-arm64 amd64}" \
  "$ROOT/scripts/build-app.sh"

rm -f "$ARCHIVE" "$ARCHIVE.sha256"
tar -czf "$ARCHIVE" -C "$ROOT/build" ACU.app

(
  cd "$ROOT/build"
  shasum -a 256 ACU.tar.gz >ACU.tar.gz.sha256
)

printf 'Packaged %s\n' "$ARCHIVE"
