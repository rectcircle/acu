#!/bin/sh
set -eu

DOMAIN=github.com.rectcircle.acu-helper
KEY=ACUTrustedTeamIdentifiers

usage() {
  printf 'Usage: %s [--add] <signed-app-path> | --clear\n' "$0" >&2
  exit 2
}

if [ "${1:-}" = "--clear" ]; then
  defaults delete "$DOMAIN" "$KEY" >/dev/null 2>&1 || true
  printf 'Trusted automation clients cleared. Restart ACU Helper.\n'
  exit 0
fi

MODE=replace
if [ "${1:-}" = "--add" ]; then
  MODE=add
  shift
fi
[ "$#" -eq 1 ] || usage

APP=$1
[ -d "$APP" ] || {
  printf 'Application not found: %s\n' "$APP" >&2
  exit 1
}

TEAM_ID=$(
  codesign -dv --verbose=4 "$APP" 2>&1 |
    sed -n 's/^TeamIdentifier=//p' |
    head -n 1
)
[ -n "$TEAM_ID" ] || {
  printf 'The selected application has no verifiable Team ID.\n' >&2
  exit 1
}

if [ "$MODE" = add ]; then
  defaults write "$DOMAIN" "$KEY" -array-add "$TEAM_ID"
else
  defaults write "$DOMAIN" "$KEY" -array "$TEAM_ID"
fi

printf 'Trusted automation client configured. Restart ACU Helper.\n'
