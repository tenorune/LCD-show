#!/usr/bin/env bash
# Shared helpers for the LCD kiosk subsystem.
# Pure functions only — no hardware/system side effects beyond the files passed
# in — so they can be unit-tested with bats.

# config_append_once FILE LINE
# Append LINE to FILE only if an identical line is not already present.
# Idempotent: running twice does not duplicate the line.
config_append_once() {
    local file="$1" line="$2"
    if grep -qxF -- "$line" "$file" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$line" >> "$file"
}

# kiosk_list_apps CONF
# Print the catalog app names (one per line), in file order.
kiosk_list_apps() {
    local conf="$1"
    grep -oE '^[[:space:]]*KIOSK_APP_[A-Za-z0-9_]+=' "$conf" \
        | sed -E 's/^[[:space:]]*KIOSK_APP_([A-Za-z0-9_]+)=.*/\1/'
}

# kiosk_get_command CONF NAME
# Print the command string for app NAME. Returns 1 if NAME is not in the catalog.
kiosk_get_command() {
    local conf="$1" name="$2" var="KIOSK_APP_$2" cmd
    # shellcheck disable=SC1090
    . "$conf"
    cmd="${!var-}"
    if [ -z "$cmd" ]; then
        return 1
    fi
    printf '%s\n' "$cmd"
}

# kiosk_get_default CONF
# Print the current KIOSK_DEFAULT value.
kiosk_get_default() {
    local conf="$1"
    # shellcheck disable=SC1090
    . "$conf"
    printf '%s\n' "${KIOSK_DEFAULT-}"
}

# kiosk_set_default CONF NAME
# Set KIOSK_DEFAULT to NAME (must exist in the catalog), rewriting in place.
# Returns 1 without modifying CONF if NAME is unknown.
kiosk_set_default() {
    local conf="$1" name="$2"
    if ! kiosk_list_apps "$conf" | grep -qxF -- "$name"; then
        printf 'lcd-kiosk: unknown app: %s\n' "$name" >&2
        return 1
    fi
    if grep -qE '^[[:space:]]*KIOSK_DEFAULT=' "$conf"; then
        sed -i -E "s|^[[:space:]]*KIOSK_DEFAULT=.*|KIOSK_DEFAULT=\"$name\"|" "$conf"
    else
        printf 'KIOSK_DEFAULT="%s"\n' "$name" >> "$conf"
    fi
}
