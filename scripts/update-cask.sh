#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf 'Usage: %s <version> <sha256>\n' "$0" >&2
  exit 1
fi

VERSION=${1#v}
SHA256=$2
if ! printf '%s\n' "$VERSION" |
  grep -Eq '^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z.-]+)?$'; then
  printf 'Invalid version: %s\n' "$1" >&2
  exit 1
fi
if ! printf '%s\n' "$SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
  printf 'Invalid SHA-256: %s\n' "$SHA256" >&2
  exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CASK="$ROOT/Casks/acu.rb"
TMP=$(mktemp "${TMPDIR:-/tmp}/acu-cask.XXXXXX")
trap 'rm -f "$TMP"' EXIT

awk -v version="$VERSION" -v sha256="$SHA256" '
  /^  version / {
    print "  version \"" version "\""
    versions++
    next
  }
  /^  sha256 / {
    print "  sha256 \"" sha256 "\""
    checksums++
    next
  }
  {
    print
  }
  END {
    if (versions != 1 || checksums != 1) {
      exit 1
    }
  }
' "$CASK" >"$TMP"

mv "$TMP" "$CASK"
trap - EXIT
