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
CHANGELOG="$ROOT/CHANGELOG.md"

if ! awk -v prefix="## [$VERSION]" '
  index($0, prefix) == 1 {
    found = 1
    next
  }
  found && /^## \[/ {
    exit
  }
  found {
    print
  }
  END {
    if (!found) {
      exit 1
    }
  }
' "$CHANGELOG"; then
  printf 'Version %s is missing from %s\n' "$VERSION" "$CHANGELOG" >&2
  exit 1
fi
