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

@test "kiosk_list_apps lists catalog names in order" {
    run kiosk_list_apps "$CONF"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "browser" ]
    [ "${lines[1]}" = "status" ]
    [ "${lines[2]}" = "menu" ]
}

@test "kiosk_get_command returns the command for a known app" {
    run kiosk_get_command "$CONF" status
    [ "$status" -eq 0 ]
    [ "$output" = "xterm -fullscreen -e htop" ]
}

@test "kiosk_get_command fails for an unknown app" {
    run kiosk_get_command "$CONF" nope
    [ "$status" -eq 1 ]
}

@test "kiosk_get_default reads the pointer" {
    run kiosk_get_default "$CONF"
    [ "$output" = "browser" ]
}

@test "kiosk_set_default updates the pointer for a known app" {
    kiosk_set_default "$CONF" status
    run kiosk_get_default "$CONF"
    [ "$output" = "status" ]
}

@test "kiosk_set_default rejects an unknown app and leaves the pointer" {
    run kiosk_set_default "$CONF" bogus
    [ "$status" -eq 1 ]
    run kiosk_get_default "$CONF"
    [ "$output" = "browser" ]
}

@test "kiosk_set_default does not duplicate the pointer line" {
    kiosk_set_default "$CONF" status
    kiosk_set_default "$CONF" menu
    run grep -c '^KIOSK_DEFAULT=' "$CONF"
    [ "$output" = "1" ]
}

@test "kiosk_set_default rewrites the config in place (preserves inode)" {
    # Regression guard for the root-owned-dir bug: the previous sed -i replaced
    # the file (new inode), which requires creating a temp file in the parent
    # directory and fails when that dir is root-owned but the file is
    # user-writable. The in-place rewrite must keep the SAME inode, so only
    # write permission on the file is needed. This holds regardless of the
    # test user (works even when CI runs as root).
    local before after
    before="$(stat -c %i "$CONF")"
    kiosk_set_default "$CONF" status
    after="$(stat -c %i "$CONF")"
    [ "$before" = "$after" ]
    run kiosk_get_default "$CONF"
    [ "$output" = "status" ]
}

@test "kiosk_find_fb locates the panel framebuffer by name (fb0)" {
    local sys="$TMP/sys"
    mkdir -p "$sys/fb0" "$sys/fb1"
    echo "fb_ili9486" > "$sys/fb0/name"
    echo "vc4" > "$sys/fb1/name"
    run kiosk_find_fb "$sys"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/fb0" ]
}

@test "kiosk_find_fb finds the panel regardless of number (fb1)" {
    local sys="$TMP/sys"
    mkdir -p "$sys/fb0" "$sys/fb1"
    echo "vc4drmfb" > "$sys/fb0/name"
    echo "fb_ili9486" > "$sys/fb1/name"
    run kiosk_find_fb "$sys"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/fb1" ]
}

@test "kiosk_find_fb returns 1 when no panel framebuffer is present" {
    local sys="$TMP/sys"
    mkdir -p "$sys/fb0"
    echo "vc4drmfb" > "$sys/fb0/name"
    run kiosk_find_fb "$sys"
    [ "$status" -eq 1 ]
}

@test "kiosk_find_fb honors LCD_FB_NAME override" {
    local sys="$TMP/sys"
    mkdir -p "$sys/fb0"
    echo "mi0283qt" > "$sys/fb0/name"
    LCD_FB_NAME="mi0283qt" run kiosk_find_fb "$sys"
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/fb0" ]
}
