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
