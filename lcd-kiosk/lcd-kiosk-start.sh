#!/usr/bin/env bash
# Launch the currently-selected kiosk app full-screen on the LCD (/dev/fb1)
# inside a dedicated minimal X server. Called by lcd-kiosk.service.
set -euo pipefail

LCD_KIOSK_LIB="${LCD_KIOSK_LIB:-/usr/local/lib/lcd-kiosk/lib.sh}"
LCD_KIOSK_CONF="${LCD_KIOSK_CONF:-/etc/lcd-kiosk/kiosk.conf}"
# shellcheck source=/dev/null
. "$LCD_KIOSK_LIB"

name="$(kiosk_get_default "$LCD_KIOSK_CONF")"
if [ -z "$name" ]; then
    echo "lcd-kiosk-start: KIOSK_DEFAULT is empty in $LCD_KIOSK_CONF" >&2
    exit 1
fi
cmd="$(kiosk_get_command "$LCD_KIOSK_CONF" "$name")" || {
    echo "lcd-kiosk-start: app '$name' not in catalog" >&2
    exit 1
}

echo "lcd-kiosk-start: launching '$name': $cmd"

# Run the app as the only client of an X server bound to /dev/fb1. 'exec' the app
# so that when it exits, X exits and systemd can restart this unit.
exec xinit /bin/sh -c "exec $cmd" -- \
    /usr/bin/Xorg :1 -config lcd-kiosk-fb1.conf -nolisten tcp -sharevts -novtswitch vt7
