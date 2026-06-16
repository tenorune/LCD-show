#!/usr/bin/env bash
# Lint every shell script that this project owns. New scripts must be added here
# as they are created.
set -euo pipefail
cd "$(dirname "$0")/.."

targets=(
    lcd-kiosk/lib.sh
    LCD35-show-safe
)

# Tolerate not-yet-created files so the gate can be run at any point in the plan.
existing=()
for t in "${targets[@]}"; do
    [ -e "$t" ] && existing+=("$t")
done

if [ "${#existing[@]}" -eq 0 ]; then
    echo "no shell targets present yet"
    exit 0
fi

shellcheck -x "${existing[@]}"
echo "shellcheck: OK (${#existing[@]} files)"
