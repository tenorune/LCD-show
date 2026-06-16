#!/usr/bin/env bats

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lcd-kiosk/lib.sh"
    # shellcheck disable=SC1090
    source "$LIB"
    TMP="$(mktemp -d)"
    CONF="$TMP/kiosk.conf"
    cat > "$CONF" <<'EOF'
KIOSK_APP_browser="chromium --kiosk file:///opt/lcd-kiosk/placeholder/index.html"
KIOSK_APP_status="xterm -fullscreen -e htop"
KIOSK_APP_menu="xterm -fullscreen -e /usr/local/bin/lcd-kiosk-menu"
KIOSK_DEFAULT="browser"
EOF
}

teardown() {
    rm -rf "$TMP"
}

@test "config_append_once adds a line when absent" {
    local f="$TMP/config.txt"
    : > "$f"
    config_append_once "$f" "dtoverlay=tft35a:rotate=90"
    run grep -c '^dtoverlay=tft35a:rotate=90$' "$f"
    [ "$output" = "1" ]
}

@test "config_append_once is idempotent" {
    local f="$TMP/config.txt"
    : > "$f"
    config_append_once "$f" "dtparam=spi=on"
    config_append_once "$f" "dtparam=spi=on"
    run grep -c '^dtparam=spi=on$' "$f"
    [ "$output" = "1" ]
}
