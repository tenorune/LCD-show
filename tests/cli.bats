#!/usr/bin/env bats

setup() {
    CLI="${BATS_TEST_DIRNAME}/../lcd-kiosk/lcd-kiosk"
    TMP="$(mktemp -d)"
    export LCD_KIOSK_LIB="${BATS_TEST_DIRNAME}/../lcd-kiosk/lib.sh"
    export LCD_KIOSK_CONF="$TMP/kiosk.conf"
    cat > "$LCD_KIOSK_CONF" <<'EOF'
KIOSK_APP_browser="chromium --kiosk x"
KIOSK_APP_status="xterm -e htop"
KIOSK_APP_menu="xterm -e /usr/local/bin/lcd-kiosk-menu"
KIOSK_DEFAULT="browser"
EOF
    # Stub sudo/systemctl so 'set' does not touch the real system.
    export PATH="$TMP/bin:$PATH"
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sudo"
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/systemctl"
    chmod +x "$TMP/bin/sudo" "$TMP/bin/systemctl"
}

teardown() { rm -rf "$TMP"; }

@test "lcd-kiosk list prints catalog" {
    run bash "$CLI" list
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "browser" ]
    [ "${lines[1]}" = "status" ]
}

@test "lcd-kiosk current prints default" {
    run bash "$CLI" current
    [ "$output" = "browser" ]
}

@test "lcd-kiosk set changes default and reports it" {
    run bash "$CLI" set status
    [ "$status" -eq 0 ]
    run bash "$CLI" current
    [ "$output" = "status" ]
}

@test "lcd-kiosk set rejects unknown app" {
    run bash "$CLI" set nope
    [ "$status" -ne 0 ]
    run bash "$CLI" current
    [ "$output" = "browser" ]
}

@test "lcd-kiosk menu sets default to menu" {
    run bash "$CLI" menu
    [ "$status" -eq 0 ]
    run bash "$CLI" current
    [ "$output" = "menu" ]
}
