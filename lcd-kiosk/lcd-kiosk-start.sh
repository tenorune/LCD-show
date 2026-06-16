#!/usr/bin/env bash
# Launch the currently-selected kiosk app full-screen on the SPI LCD inside a
# dedicated minimal X server. Called by lcd-kiosk.service. The panel's
# framebuffer is located by name at runtime (its /dev/fbN number is not stable),
# and the fbdev X driver is pointed at it via the FRAMEBUFFER environment var.
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

# Locate the SPI panel's framebuffer by name (its number is not stable) and
# point the fbdev X driver at it via FRAMEBUFFER (honoured when the Xorg config
# does not hard-code a device).
fbdev="$(kiosk_find_fb)" || {
    echo "lcd-kiosk-start: SPI panel framebuffer (name '${LCD_FB_NAME:-fb_ili9486}') not found" >&2
    exit 1
}
export FRAMEBUFFER="$fbdev"

echo "lcd-kiosk-start: launching '$name' on $fbdev: $cmd"

# Run the app as the only client of an X server bound to the SPI panel. 'exec'
# the app so that when it exits, X exits and systemd can restart this unit.
exec xinit /bin/sh -c "exec $cmd" -- \
    /usr/bin/Xorg :1 -config lcd-kiosk-fb1.conf -nolisten tcp -sharevts -novtswitch vt7
