#!/usr/bin/env bash
# Milestone 2 installer: install the kiosk launcher, selectors, service, and
# supporting config. Run AFTER LCD35-show-safe and a successful reboot.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo ./install-kiosk.sh" >&2
    exit 1
fi

user="$(logname 2>/dev/null || echo "${SUDO_USER:-}")"
if [ -z "$user" ]; then
    echo "Could not determine the desktop user. Set SUDO_USER and retry." >&2
    exit 1
fi
echo "Installing kiosk for user: $user"

# --- Packages ----------------------------------------------------------------
apt-get update
apt-get install -y chromium xterm yad python3-evdev whiptail

# --- Library + executables ---------------------------------------------------
install -d /usr/local/lib/lcd-kiosk
install -m 0644 "$here/lcd-kiosk/lib.sh" /usr/local/lib/lcd-kiosk/lib.sh
install -m 0755 "$here/lcd-kiosk/lcd-kiosk-start.sh" /usr/local/bin/lcd-kiosk-start
install -m 0755 "$here/lcd-kiosk/lcd-kiosk"          /usr/local/bin/lcd-kiosk
install -m 0755 "$here/lcd-kiosk/lcd-kiosk-menu"     /usr/local/bin/lcd-kiosk-menu
install -m 0755 "$here/lcd-kiosk/lcd-kiosk-touchd"   /usr/local/bin/lcd-kiosk-touchd

# --- Config (do not overwrite an existing user config) -----------------------
install -d /etc/lcd-kiosk
if [ ! -f /etc/lcd-kiosk/kiosk.conf ]; then
    install -m 0644 "$here/lcd-kiosk/kiosk.conf" /etc/lcd-kiosk/kiosk.conf
fi
# The selectors write this file as the desktop user (no sudo needed).
chown "$user":"$user" /etc/lcd-kiosk/kiosk.conf

install -d /opt/lcd-kiosk/placeholder
install -m 0644 "$here/lcd-kiosk/placeholder/index.html" /opt/lcd-kiosk/placeholder/index.html
install -m 0644 "$here/lcd-kiosk/lcd-kiosk-fb1.conf" /etc/X11/lcd-kiosk-fb1.conf

# --- Allow a non-root user to start X ----------------------------------------
cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# --- Let the desktop user restart the kiosk without a password ---------------
# Write atomically and validate before moving into place, so an interrupted or
# malformed write can never corrupt the live sudoers and lock out sudo.
sudoers_tmp="$(mktemp /etc/sudoers.d/.lcd-kiosk.XXXXXX)"
printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl restart lcd-kiosk.service\n' "$user" > "$sudoers_tmp"
chmod 0440 "$sudoers_tmp"
if visudo -c -f "$sudoers_tmp" >/dev/null; then
    mv "$sudoers_tmp" /etc/sudoers.d/lcd-kiosk
else
    rm -f "$sudoers_tmp"
    echo "Generated sudoers entry failed validation; aborting." >&2
    exit 1
fi

# --- systemd units -----------------------------------------------------------
install -m 0644 "$here/lcd-kiosk/lcd-kiosk.service" /etc/systemd/system/lcd-kiosk.service
install -d /etc/systemd/system/lcd-kiosk.service.d
cat > /etc/systemd/system/lcd-kiosk.service.d/user.conf <<EOF
[Service]
User=$user
EOF
install -m 0644 "$here/lcd-kiosk/lcd-kiosk-touchd.service" /etc/systemd/system/lcd-kiosk-touchd.service

systemctl daemon-reload
systemctl enable --now lcd-kiosk.service
systemctl enable --now lcd-kiosk-touchd.service

echo
# shellcheck source=/dev/null
echo "Kiosk installed. The LCD should now show: $(. /usr/local/lib/lcd-kiosk/lib.sh; kiosk_get_default /etc/lcd-kiosk/kiosk.conf)"
echo "Change it with:  lcd-kiosk            (interactive)"
echo "             or:  lcd-kiosk set status"
echo "Logs:            journalctl -u lcd-kiosk -b"
