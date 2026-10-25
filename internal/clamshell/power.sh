#!/bin/sh
# Installed root-owned. No user-controlled paths, commands, or environment.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset ENV BASH_ENV CDPATH
[ "$(/usr/bin/id -u)" = 0 ] || exit 1
[ "$#" = 1 ] || exit 2
case "$1" in on|off) ;; *) exit 2 ;; esac
case "${SUDO_UID:-}" in ''|*[!0-9]*) exit 2 ;; esac
state=/var/db/acu-clamshell
/usr/bin/shlock -f "$state/lock" -p $$ || exit 3
trap '/bin/rm -f /var/db/acu-clamshell/lock' EXIT
current() {
    /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" && ($2 == 0 || $2 == 1) { print $2; found=1; exit } END { if (!found) exit 1 }'
}
if [ -f "$state/session" ]; then
    read -r owner original < "$state/session"
    [ "$owner" = "$SUDO_UID" ] || { echo 'Another user owns the active session.' >&2; exit 4; }
    case "$original" in 0|1) ;; *) exit 5 ;; esac
fi
case "$1" in
on)
    if [ ! -f "$state/session" ]; then
        original=$(current)
        umask 022
        printf '%s %s\n' "$SUDO_UID" "$original" > "$state/session.new"
        /bin/mv -f "$state/session.new" "$state/session"
    fi
    /usr/bin/pmset -a disablesleep 1
    [ "$(current)" = 1 ]
    ;;
off)
    [ -f "$state/session" ] || exit 0
    /usr/bin/pmset -a disablesleep "$original"
    [ "$(current)" = "$original" ]
    /bin/rm "$state/session"
    ;;
esac
