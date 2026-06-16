# Wayland-safe LCD + Kiosk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configure a goodtft 3.5″ SPI display (ILI9486 panel + XPT2046 touch) on Raspberry Pi OS Trixie so it shows a swappable single kiosk app with working touch, while keeping the `labwc`/Wayland session intact so Raspberry Pi Connect keeps working.

**Architecture:** Two non-conflicting display stacks. The primary `labwc` (Wayland) session keeps owning the KMS card (untouched, captured by Connect). The LCD comes up as a legacy framebuffer `/dev/fb1` via the `tft35a` overlay; a dedicated minimal X server bound to `/dev/fb1` runs one full-screen kiosk app. A single `KIOSK_DEFAULT` pointer in `kiosk.conf` is the source of truth, written by three selection surfaces (boot default, shell `lcd-kiosk` command, on-LCD touch menu). Pure shell logic lives in a sourced, unit-tested `lib.sh`; hardware-touching scripts are thin and verified on the Pi.

**Tech Stack:** Bash, `bats` (unit tests), `shellcheck` (lint), Raspberry Pi device-tree overlays, Xorg (`fbdev` driver + `evdev` input), systemd, `whiptail`/`yad` (menus), `python3-evdev` (gesture watcher), Chromium.

**Hardware-testing note:** The development environment has no display/Pi, so the `lib.sh` logic is fully unit-tested here, and every hardware-dependent script has explicit "run this on the Pi and report output" verification steps. Expect an iteration loop on the panel/touch/X parts — the device-tree and X-on-fb1 specifics in this plan are a complete *first attempt* to validate and tune on the actual board.

**Conventions used by every script:**
- Scripts source the shared library via `LCD_KIOSK_LIB="${LCD_KIOSK_LIB:-/usr/local/lib/lcd-kiosk/lib.sh}"` and read config via `LCD_KIOSK_CONF="${LCD_KIOSK_CONF:-/etc/lcd-kiosk/kiosk.conf}"`, so tests can override both with in-repo paths.
- `/etc/lcd-kiosk/kiosk.conf` is owned by the desktop user, so selection writes need no `sudo`; the service restart is allowed via a NOPASSWD sudoers drop-in.

---

## File structure

| Path (in repo) | Installed to | Responsibility |
|---|---|---|
| `lcd-kiosk/lib.sh` | `/usr/local/lib/lcd-kiosk/lib.sh` | Pure, testable helpers: idempotent config edit; catalog get/set/list |
| `tests/lib.bats` | — | Unit tests for `lib.sh` |
| `tests/run-shellcheck.sh` | — | Lints all shell scripts |
| `lcd-kiosk/kiosk.conf` | `/etc/lcd-kiosk/kiosk.conf` | Catalog of named apps + `KIOSK_DEFAULT` pointer |
| `lcd-kiosk/placeholder/index.html` | `/opt/lcd-kiosk/placeholder/index.html` | Default browser page |
| `lcd-kiosk/lcd-kiosk-fb1.conf` | `/etc/X11/lcd-kiosk-fb1.conf` | Xorg config: fbdev on `/dev/fb1` + evdev touch + calibration |
| `lcd-kiosk/lcd-kiosk-start.sh` | `/usr/local/bin/lcd-kiosk-start` | Deterministic launcher (service calls this) |
| `lcd-kiosk/lcd-kiosk` | `/usr/local/bin/lcd-kiosk` | Shell selector CLI |
| `lcd-kiosk/lcd-kiosk-menu` | `/usr/local/bin/lcd-kiosk-menu` | On-LCD touch menu (yad) |
| `lcd-kiosk/lcd-kiosk-touchd` | `/usr/local/bin/lcd-kiosk-touchd` | Gesture watcher that summons the menu |
| `lcd-kiosk/lcd-kiosk.service` | `/etc/systemd/system/lcd-kiosk.service` | Runs the launcher |
| `lcd-kiosk/lcd-kiosk-touchd.service` | `/etc/systemd/system/lcd-kiosk-touchd.service` | Runs the gesture watcher |
| `lcd-kiosk/99-lcd-touch-ignore.rules` | `/etc/udev/rules.d/99-lcd-touch-ignore.rules` | Make labwc/libinput ignore the touchscreen (kiosk X keeps it) |
| `LCD35-show-safe` | — (run in place) | **M1** installer: panel + touch, keep Wayland |
| `install-kiosk.sh` | — (run in place) | **M2** installer: kiosk files + services |
| `LCD-revert` | — (run in place) | Uninstaller |
| `docs/lcd-kiosk.md` | — | User guide: verification + Approach A upgrade path |

---

## Phase 0 — Shared library + test harness (fully testable in this environment)

### Task 1: Idempotent config-edit helper

**Files:**
- Create: `lcd-kiosk/lib.sh`
- Test: `tests/lib.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/lib.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/lib.bats`
Expected: FAIL — `lib.sh` does not exist / `config_append_once` not found.

- [ ] **Step 3: Write the minimal implementation**

Create `lcd-kiosk/lib.sh`:

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/lib.bats`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lcd-kiosk/lib.sh tests/lib.bats
git commit -m "Add idempotent config_append_once helper with tests"
```

---

### Task 2: Kiosk catalog get/set/list helpers

**Files:**
- Modify: `lcd-kiosk/lib.sh`
- Test: `tests/lib.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/lib.bats`:

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/lib.bats`
Expected: the new tests FAIL — functions not defined.

- [ ] **Step 3: Write the minimal implementation**

Append to `lcd-kiosk/lib.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/lib.bats`
Expected: PASS (9 tests total).

- [ ] **Step 5: Commit**

```bash
git add lcd-kiosk/lib.sh tests/lib.bats
git commit -m "Add kiosk catalog get/set/list helpers with tests"
```

---

### Task 3: Shellcheck lint gate

**Files:**
- Create: `tests/run-shellcheck.sh`

- [ ] **Step 1: Write the lint runner**

Create `tests/run-shellcheck.sh`:

```bash
#!/usr/bin/env bash
# Lint every shell script that this project owns. New scripts must be added here
# as they are created.
set -euo pipefail
cd "$(dirname "$0")/.."

targets=(
    lcd-kiosk/lib.sh
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
```

- [ ] **Step 2: Run it and confirm it passes**

Run: `bash tests/run-shellcheck.sh`
Expected: `shellcheck: OK (1 files)`. If `lib.sh` reports warnings, fix them (the `# shellcheck disable=` directives above cover the intentional `source`/indirect-expansion cases).

- [ ] **Step 3: Commit**

```bash
git add tests/run-shellcheck.sh
git commit -m "Add shellcheck lint gate"
```

> **Note for later tasks:** every task that creates a new shell script adds its path to the `targets` array in `tests/run-shellcheck.sh` and re-runs `bash tests/run-shellcheck.sh` before committing.

---

## Phase 1 — Milestone 1: panel + touch, keep Wayland/Connect

This phase produces the `LCD35-show-safe` installer. Its job: bring up `/dev/fb1` and touch **without** disabling Wayland. After this phase the LCD shows the text console and `evtest` sees touch events, and Connect still works.

### Task 4: Catalog config + placeholder page

**Files:**
- Create: `lcd-kiosk/kiosk.conf`
- Create: `lcd-kiosk/placeholder/index.html`

- [ ] **Step 1: Create the catalog config**

Create `lcd-kiosk/kiosk.conf`:

```bash
# LCD kiosk configuration.
#
# Catalog: each KIOSK_APP_<name> maps a short name to a command run full-screen
# on the LCD. Add your own by copying a line and changing the name and command.
# The command may be any X client (browser, terminal, GUI app).
KIOSK_APP_browser="chromium --kiosk --noerrdialogs --disable-infobars --check-for-update-interval=31536000 file:///opt/lcd-kiosk/placeholder/index.html"
KIOSK_APP_status="xterm -fullscreen -fa Monospace -fs 10 -e htop"
KIOSK_APP_menu="xterm -fullscreen -e /usr/local/bin/lcd-kiosk-menu"

# Which app to show. This is also the boot default; the selectors rewrite it.
KIOSK_DEFAULT="browser"
```

- [ ] **Step 2: Create the placeholder page**

Create `lcd-kiosk/placeholder/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=480, initial-scale=1">
<title>LCD kiosk</title>
<style>
  html,body{margin:0;height:100%;background:#111;color:#eee;
    font-family:system-ui,sans-serif;display:flex;align-items:center;
    justify-content:center;text-align:center}
  .box{padding:1rem}
  h1{font-size:1.4rem;margin:0 0 .4rem}
  p{font-size:.9rem;color:#9bd}
  code{color:#fc8}
</style>
</head>
<body>
  <div class="box">
    <h1>LCD kiosk ready</h1>
    <p>Edit <code>/etc/lcd-kiosk/kiosk.conf</code> or run <code>lcd-kiosk</code> to change what shows here.</p>
  </div>
</body>
</html>
```

- [ ] **Step 3: Verify the config parses with the library**

Run:
```bash
LCD_KIOSK_LIB=lcd-kiosk/lib.sh bash -c '. lcd-kiosk/lib.sh; kiosk_list_apps lcd-kiosk/kiosk.conf; echo "default: $(kiosk_get_default lcd-kiosk/kiosk.conf)"'
```
Expected output:
```
browser
status
menu
default: browser
```

- [ ] **Step 4: Commit**

```bash
git add lcd-kiosk/kiosk.conf lcd-kiosk/placeholder/index.html
git commit -m "Add kiosk catalog config and placeholder page"
```

---

### Task 5: Touch-ignore udev rule + kiosk Xorg config

These two files make touch work for the kiosk X server while keeping it away from the Wayland session. They are static config; verification is on the Pi in Task 8.

**Files:**
- Create: `lcd-kiosk/99-lcd-touch-ignore.rules`
- Create: `lcd-kiosk/lcd-kiosk-fb1.conf`

- [ ] **Step 1: Create the udev ignore rule**

Create `lcd-kiosk/99-lcd-touch-ignore.rules`:

```
# Make the Wayland compositor's libinput ignore the XPT2046/ADS7846 touchscreen,
# so the dedicated kiosk X server (which uses xserver-xorg-input-evdev, not
# libinput) is the only consumer. This keeps the touchscreen driving the LCD
# kiosk rather than the remote desktop cursor.
SUBSYSTEM=="input", ATTRS{name}=="ADS7846 Touchscreen", ENV{LIBINPUT_IGNORE_DEVICE}="1"
```

- [ ] **Step 2: Create the kiosk Xorg config**

Create `lcd-kiosk/lcd-kiosk-fb1.conf` (calibration values reused from this repo's `usr/99-calibration.conf-35-90`):

```
# Minimal Xorg config for the LCD kiosk: render to the SPI framebuffer /dev/fb1
# with the fbdev driver, and take touch from the evdev driver so the calibration
# below applies. Referenced explicitly by lcd-kiosk-start (never auto-loaded).
Section "ServerFlags"
    Option "AutoAddGPU" "false"
    Option "DontVTSwitch" "true"
EndSection

Section "Device"
    Identifier "LCD-fbdev"
    Driver     "fbdev"
    Option     "fbdev" "/dev/fb1"
EndSection

Section "Monitor"
    Identifier "LCD-monitor"
EndSection

Section "Screen"
    Identifier "LCD-screen"
    Device     "LCD-fbdev"
    Monitor    "LCD-monitor"
EndSection

Section "ServerLayout"
    Identifier "LCD-layout"
    Screen     "LCD-screen"
EndSection

Section "InputClass"
    Identifier  "LCD-touch"
    MatchProduct "ADS7846 Touchscreen"
    Driver      "evdev"
    Option      "Calibration" "3936 227 268 3880"
    Option      "SwapAxes" "1"
    Option      "GrabDevice" "false"
EndSection
```

- [ ] **Step 3: Commit**

```bash
git add lcd-kiosk/99-lcd-touch-ignore.rules lcd-kiosk/lcd-kiosk-fb1.conf
git commit -m "Add touch-ignore udev rule and kiosk Xorg config"
```

---

### Task 6: `LCD35-show-safe` installer (Milestone 1)

**Files:**
- Create: `LCD35-show-safe`
- Modify: `tests/run-shellcheck.sh` (add target)

- [ ] **Step 1: Write the installer**

Create `LCD35-show-safe`:

```bash
#!/usr/bin/env bash
# Milestone 1 installer: bring up the goodtft 3.5" SPI panel (/dev/fb1) and the
# XPT2046 touch input on Raspberry Pi OS Trixie WITHOUT disabling Wayland, so
# Raspberry Pi Connect keeps working. After running this and rebooting, the LCD
# shows the text console and the touchscreen produces input events.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
LCD_KIOSK_LIB="$here/lcd-kiosk/lib.sh"
# shellcheck source=lcd-kiosk/lib.sh
. "$LCD_KIOSK_LIB"

CONFIG_TXT="/boot/firmware/config.txt"

# --- Preconditions -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo ./LCD35-show-safe" >&2
    exit 1
fi

deb_version="$(cat /etc/debian_version 2>/dev/null | tr -d '\n')"
case "$deb_version" in
    13*|trixie*) : ;;
    *) echo "This installer targets Raspberry Pi OS Trixie (Debian 13). Found: '$deb_version'. Aborting." >&2; exit 1 ;;
esac

if [ ! -f "$CONFIG_TXT" ]; then
    echo "Expected $CONFIG_TXT (Trixie layout) not found. Aborting." >&2
    exit 1
fi

# --- Backup ------------------------------------------------------------------
backup="$CONFIG_TXT.lcd-safe.bak"
if [ ! -f "$backup" ]; then
    cp -a "$CONFIG_TXT" "$backup"
    echo "Backed up $CONFIG_TXT -> $backup"
else
    echo "Backup already exists: $backup (left untouched)"
fi

# --- Packages ----------------------------------------------------------------
echo "Installing X server + fbdev + evdev packages..."
apt-get update
apt-get install -y xserver-xorg-core xserver-xorg-video-fbdev \
    xserver-xorg-input-evdev xinit x11-xserver-utils evtest

# --- Device-tree overlay -----------------------------------------------------
echo "Installing tft35a overlay..."
cp "$here/usr/tft35a-overlay.dtb" /boot/firmware/overlays/tft35a.dtbo

# --- config.txt edits (idempotent; KMS/Wayland left intact) -------------------
echo "Editing $CONFIG_TXT (keeping vc4-kms-v3d enabled)..."
config_append_once "$CONFIG_TXT" "dtparam=spi=on"
config_append_once "$CONFIG_TXT" "dtoverlay=tft35a:rotate=90"
config_append_once "$CONFIG_TXT" "dtoverlay=ads7846,cs=1,penirq=25,penirq_pull=2,speed=50000,keep_vref_on=0,swapxy=0,pmax=255,xohms=150,xmin=200,xmax=3900,ymin=200,ymax=3900"

# --- Touch routing -----------------------------------------------------------
echo "Installing touch-ignore udev rule for the Wayland session..."
cp "$here/lcd-kiosk/99-lcd-touch-ignore.rules" /etc/udev/rules.d/99-lcd-touch-ignore.rules

echo
echo "Milestone 1 install complete."
echo "We did NOT change your Wayland session or boot target, so Raspberry Pi"
echo "Connect should keep working."
echo
echo "Verify after reboot:"
echo "  1) ls -l /dev/fb1            # the SPI panel framebuffer should exist"
echo "  2) sudo evtest              # pick 'ADS7846 Touchscreen', touch the panel"
echo "  3) rpi-connect doctor       # should report a Wayland compositor"
echo
read -r -p "Reboot now to apply? [y/N] " ans
case "$ans" in
    y|Y) reboot ;;
    *) echo "Not rebooting. Reboot manually to apply changes." ;;
esac
```

- [ ] **Step 2: Add it to the lint gate and lint**

In `tests/run-shellcheck.sh`, change the `targets` array to:

```bash
targets=(
    lcd-kiosk/lib.sh
    LCD35-show-safe
)
```

Run: `bash tests/run-shellcheck.sh`
Expected: `shellcheck: OK (2 files)`. Fix any warnings before continuing.

- [ ] **Step 3: Syntax-check and make executable**

Run:
```bash
bash -n LCD35-show-safe && chmod +x LCD35-show-safe && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add LCD35-show-safe tests/run-shellcheck.sh
git commit -m "Add Milestone 1 installer (panel + touch, keep Wayland)"
```

---

### Task 7: Milestone 1 on-Pi verification (manual)

**This task is run by the user on the Raspberry Pi. No code changes.**

- [ ] **Step 1: Copy the branch to the Pi and run the installer**

On the Pi:
```bash
git clone -b claude/vigilant-sagan-ubm2ub https://github.com/tenorune/LCD-show.git
cd LCD-show
sudo ./LCD35-show-safe
# answer 'y' to reboot
```

- [ ] **Step 2: Verify panel, touch, and Connect**

After reboot, report the output of:
```bash
ls -l /dev/fb1                       # expect a character device to exist
dmesg | grep -iE 'fb_ili9486|tft35a|ads7846'   # expect panel + touch probe lines
sudo evtest                          # select ADS7846; touch panel; expect events
rpi-connect doctor                   # expect "Wayland compositor" OK
```

**Acceptance:** `/dev/fb1` exists, the LCD shows console text, `evtest` shows touch events, and `rpi-connect doctor` reports a Wayland compositor with screen sharing working.

- [ ] **Step 3: If touch does not appear**

Report `evtest` device list and `dmesg | grep -i ads7846`. The likely fix is dropping the separate `dtoverlay=ads7846` line (if the `tft35a` overlay already includes touch and the two conflict) — we will adjust `LCD35-show-safe` and re-verify. **Do not proceed to Phase 2 until acceptance passes.**

---

## Phase 2 — Milestone 2: kiosk launcher + default-on-boot

### Task 8: Kiosk launcher script

**Files:**
- Create: `lcd-kiosk/lcd-kiosk-start.sh`
- Modify: `tests/run-shellcheck.sh` (add target)

- [ ] **Step 1: Write the launcher**

Create `lcd-kiosk/lcd-kiosk-start.sh`:

```bash
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
```

- [ ] **Step 2: Lint and syntax-check**

Add `lcd-kiosk/lcd-kiosk-start.sh` to `targets` in `tests/run-shellcheck.sh`, then:
```bash
bash tests/run-shellcheck.sh && bash -n lcd-kiosk/lcd-kiosk-start.sh && echo OK
```
Expected: `shellcheck: OK (3 files)` then `OK`.

- [ ] **Step 3: Commit**

```bash
git add lcd-kiosk/lcd-kiosk-start.sh tests/run-shellcheck.sh
git commit -m "Add kiosk launcher (X-on-fb1, runs selected app)"
```

---

### Task 9: systemd unit + `install-kiosk.sh`

**Files:**
- Create: `lcd-kiosk/lcd-kiosk.service`
- Create: `install-kiosk.sh`
- Modify: `tests/run-shellcheck.sh` (add target)

- [ ] **Step 1: Write the service unit**

Create `lcd-kiosk/lcd-kiosk.service`:

```ini
[Unit]
Description=LCD kiosk (single app on the SPI display)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/lcd-kiosk-start
Restart=on-failure
RestartSec=3
# User= is provided by an installer-generated drop-in (the desktop user).

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Write the M2 installer**

Create `install-kiosk.sh`:

```bash
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
cat > /etc/sudoers.d/lcd-kiosk <<EOF
$user ALL=(root) NOPASSWD: /usr/bin/systemctl restart lcd-kiosk.service
EOF
chmod 0440 /etc/sudoers.d/lcd-kiosk

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
echo "Kiosk installed. The LCD should now show: $(. /usr/local/lib/lcd-kiosk/lib.sh; kiosk_get_default /etc/lcd-kiosk/kiosk.conf)"
echo "Change it with:  lcd-kiosk            (interactive)"
echo "             or:  lcd-kiosk set status"
echo "Logs:            journalctl -u lcd-kiosk -b"
```

- [ ] **Step 3: Lint and syntax-check**

Add `install-kiosk.sh` to `targets` in `tests/run-shellcheck.sh`, then:
```bash
bash tests/run-shellcheck.sh && bash -n install-kiosk.sh && chmod +x install-kiosk.sh && echo OK
```
Expected: `shellcheck: OK (4 files)` then `OK`.

- [ ] **Step 4: Commit**

```bash
git add lcd-kiosk/lcd-kiosk.service install-kiosk.sh tests/run-shellcheck.sh
git commit -m "Add kiosk systemd service and Milestone 2 installer"
```

---

### Task 10: Shell selector CLI

**Files:**
- Create: `lcd-kiosk/lcd-kiosk`
- Modify: `tests/run-shellcheck.sh` (add target)
- Test: `tests/cli.bats`

- [ ] **Step 1: Write a failing test for the read-only subcommands**

Create `tests/cli.bats`:

```bash
#!/usr/bin/env bats

setup() {
    CLI="${BATS_TEST_DIRNAME}/../lcd-kiosk/lcd-kiosk"
    TMP="$(mktemp -d)"
    export LCD_KIOSK_LIB="${BATS_TEST_DIRNAME}/../lcd-kiosk/lib.sh"
    export LCD_KIOSK_CONF="$TMP/kiosk.conf"
    cat > "$LCD_KIOSK_CONF" <<'EOF'
KIOSK_APP_browser="chromium --kiosk x"
KIOSK_APP_status="xterm -e htop"
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/cli.bats`
Expected: FAIL — `lcd-kiosk` does not exist.

- [ ] **Step 3: Write the CLI**

Create `lcd-kiosk/lcd-kiosk`:

```bash
#!/usr/bin/env bash
# Select which kiosk app the LCD shows. Updates the boot default (KIOSK_DEFAULT)
# and restarts the kiosk so the change takes effect immediately.
set -euo pipefail

LCD_KIOSK_LIB="${LCD_KIOSK_LIB:-/usr/local/lib/lcd-kiosk/lib.sh}"
LCD_KIOSK_CONF="${LCD_KIOSK_CONF:-/etc/lcd-kiosk/kiosk.conf}"
# shellcheck source=/dev/null
. "$LCD_KIOSK_LIB"

usage() {
    cat <<EOF
Usage: lcd-kiosk [command]
  list            List available kiosk apps
  current         Show the current default app
  set <name>      Set the default app and switch the LCD to it
  menu            Switch the LCD to the on-screen touch menu
  (no command)    Interactive picker
EOF
}

apply() {
    # Restart the kiosk if the service exists; ignore failures (e.g. pre-install).
    sudo systemctl restart lcd-kiosk.service 2>/dev/null || true
}

set_and_apply() {
    local name="$1"
    if ! kiosk_set_default "$LCD_KIOSK_CONF" "$name"; then
        echo "Available apps:" >&2
        kiosk_list_apps "$LCD_KIOSK_CONF" | sed 's/^/  /' >&2
        return 1
    fi
    apply
    echo "LCD set to: $name"
}

pick_interactive() {
    local apps=() items=() choice a
    mapfile -t apps < <(kiosk_list_apps "$LCD_KIOSK_CONF")
    for a in "${apps[@]}"; do items+=("$a" ""); done
    choice="$(whiptail --title "LCD kiosk" \
        --menu "Choose what to show on the LCD:" 15 50 6 \
        "${items[@]}" 3>&1 1>&2 2>&3)" || return 0
    set_and_apply "$choice"
}

case "${1-}" in
    list)    kiosk_list_apps "$LCD_KIOSK_CONF" ;;
    current) kiosk_get_default "$LCD_KIOSK_CONF" ;;
    set)
        [ $# -ge 2 ] || { usage; exit 2; }
        set_and_apply "$2"
        ;;
    menu)    set_and_apply menu ;;
    "")      pick_interactive ;;
    -h|--help) usage ;;
    *)       usage; exit 2 ;;
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint**

Add `lcd-kiosk/lcd-kiosk` to `targets` in `tests/run-shellcheck.sh`, then run `bash tests/run-shellcheck.sh`.
Expected: `shellcheck: OK (5 files)`. Fix warnings.

- [ ] **Step 6: Commit**

```bash
git add lcd-kiosk/lcd-kiosk tests/cli.bats tests/run-shellcheck.sh
git commit -m "Add lcd-kiosk shell selector with tests"
```

---

### Task 11: Milestone 2 (boot default + shell selector) on-Pi verification (manual)

**Run by the user on the Pi after Task 7 passed. No code changes.**

- [ ] **Step 1: Install the kiosk**

On the Pi, in the cloned repo (pull the latest branch first):
```bash
git pull
sudo ./install-kiosk.sh
```

- [ ] **Step 2: Verify default-on-boot and the shell selector**

```bash
systemctl status lcd-kiosk --no-pager      # expect active (running)
# LCD should show full-screen Chromium placeholder page.
lcd-kiosk list                             # browser / status / menu
lcd-kiosk set status                       # LCD switches to htop
lcd-kiosk current                          # status
sudo reboot
# after reboot:
lcd-kiosk current                          # still 'status' -> persisted as default
rpi-connect doctor                         # still OK
```

**Acceptance:** Chromium fills the LCD on boot; `lcd-kiosk set status` switches the LCD and survives reboot; touch lands where you tap; Connect still works.

- [ ] **Step 3: If the X server fails to start on `/dev/fb1`**

Report `journalctl -u lcd-kiosk -b --no-pager` and `cat /var/log/Xorg.1.log`. Likely tuning points (we iterate here): the `vt7`/`-sharevts`/`-novtswitch` flags in `lcd-kiosk-start.sh`, or `Xwrapper.config`. **Do not proceed to Phase 3 until acceptance passes.**

---

## Phase 3 — Touch menu (on-LCD selector)

### Task 12: On-LCD touch menu (`lcd-kiosk-menu`)

**Files:**
- Create: `lcd-kiosk/lcd-kiosk-menu`
- Modify: `tests/run-shellcheck.sh` (add target)

- [ ] **Step 1: Write the menu**

Create `lcd-kiosk/lcd-kiosk-menu`:

```bash
#!/usr/bin/env bash
# On-LCD touch menu. Renders the kiosk catalog as a touch-clickable list (yad);
# selecting an entry sets it as the default and switches the LCD to it. Intended
# to run as the 'menu' kiosk app (inside the fb1 X server).
set -euo pipefail

LCD_KIOSK_LIB="${LCD_KIOSK_LIB:-/usr/local/lib/lcd-kiosk/lib.sh}"
LCD_KIOSK_CONF="${LCD_KIOSK_CONF:-/etc/lcd-kiosk/kiosk.conf}"
# shellcheck source=/dev/null
. "$LCD_KIOSK_LIB"

# Build the choosable list (exclude the menu entry itself).
mapfile -t choices < <(kiosk_list_apps "$LCD_KIOSK_CONF" | grep -vx menu)

choice="$(printf '%s\n' "${choices[@]}" \
    | yad --list --title="LCD menu" --no-headers \
          --column="Show on LCD" --width=320 --height=240 \
          --button="Select:0" 2>/dev/null)" || exit 0

choice="${choice%|}"   # yad appends a trailing field separator
[ -n "$choice" ] || exit 0

# Persist + switch. lcd-kiosk restarts the service, replacing this menu with the
# chosen app.
lcd-kiosk set "$choice"
```

- [ ] **Step 2: Lint and syntax-check**

Add `lcd-kiosk/lcd-kiosk-menu` to `targets` in `tests/run-shellcheck.sh`, then:
```bash
bash tests/run-shellcheck.sh && bash -n lcd-kiosk/lcd-kiosk-menu && echo OK
```
Expected: `shellcheck: OK (6 files)` then `OK`.

- [ ] **Step 3: Commit**

```bash
git add lcd-kiosk/lcd-kiosk-menu tests/run-shellcheck.sh
git commit -m "Add on-LCD touch menu (yad)"
```

---

### Task 13: Gesture watcher (`lcd-kiosk-touchd`) + service

**Files:**
- Create: `lcd-kiosk/lcd-kiosk-touchd`
- Create: `lcd-kiosk/lcd-kiosk-touchd.service`

> This is the highest-risk piece (per the spec). The script below is a complete first attempt; the reliable fallback (`lcd-kiosk menu` from a shell, or setting `menu` as the default) always works regardless.

- [ ] **Step 1: Write the watcher**

Create `lcd-kiosk/lcd-kiosk-touchd` (Python — uses `python3-evdev`):

```python
#!/usr/bin/env python3
"""Watch the touchscreen and, on a long-press held in the top-left corner,
invoke `lcd-kiosk menu` to summon the on-LCD menu. Best-effort convenience; the
shell command `lcd-kiosk menu` always works as a fallback.

The watcher reads events in parallel with the kiosk X server (which is configured
with GrabDevice off), and only observes — it never consumes taps.
"""
import os
import subprocess
import time

from evdev import InputDevice, ecodes, list_devices

DEVICE_NAME = os.environ.get("LCD_TOUCH_NAME", "ADS7846 Touchscreen")
CORNER_FRAC = float(os.environ.get("LCD_TOUCH_CORNER_FRAC", "0.25"))
HOLD_SECONDS = float(os.environ.get("LCD_TOUCH_HOLD_SECONDS", "1.5"))


def find_device():
    for path in list_devices():
        dev = InputDevice(path)
        if DEVICE_NAME in dev.name:
            return dev
    return None


def axis_range(dev, code):
    for c, absinfo in dev.capabilities().get(ecodes.EV_ABS, []):
        if c == code:
            return absinfo.min, absinfo.max
    return 0, 4095


def main():
    dev = None
    while dev is None:
        dev = find_device()
        if dev is None:
            time.sleep(2)

    xmin, xmax = axis_range(dev, ecodes.ABS_X)
    ymin, ymax = axis_range(dev, ecodes.ABS_Y)
    x_thresh = xmin + (xmax - xmin) * CORNER_FRAC
    y_thresh = ymin + (ymax - ymin) * CORNER_FRAC

    x = y = None
    touching = False
    press_start = 0.0
    fired = False

    for ev in dev.read_loop():
        if ev.type == ecodes.EV_ABS:
            if ev.code == ecodes.ABS_X:
                x = ev.value
            elif ev.code == ecodes.ABS_Y:
                y = ev.value
        elif ev.type == ecodes.EV_KEY and ev.code == ecodes.BTN_TOUCH:
            touching = ev.value == 1
            if touching:
                press_start = time.time()
                fired = False
            continue

        if touching and not fired and x is not None and y is not None:
            in_corner = x <= x_thresh and y <= y_thresh
            if in_corner and (time.time() - press_start) >= HOLD_SECONDS:
                fired = True
                subprocess.Popen(["lcd-kiosk", "menu"])


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the watcher service**

Create `lcd-kiosk/lcd-kiosk-touchd.service`:

```ini
[Unit]
Description=LCD kiosk touch-gesture watcher (summons the on-LCD menu)
After=lcd-kiosk.service

[Service]
Type=simple
ExecStart=/usr/local/bin/lcd-kiosk-touchd
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Byte-compile the Python to catch syntax errors**

Run:
```bash
python3 -m py_compile lcd-kiosk/lcd-kiosk-touchd && echo "python syntax OK"
```
Expected: `python syntax OK`. (The `evdev` import is only exercised on the Pi.)

- [ ] **Step 4: Commit**

```bash
git add lcd-kiosk/lcd-kiosk-touchd lcd-kiosk/lcd-kiosk-touchd.service
git commit -m "Add touch-gesture watcher to summon the on-LCD menu"
```

---

### Task 14: Touch menu on-Pi verification (manual)

**Run by the user on the Pi after Task 11 passed. No code changes.**

- [ ] **Step 1: Update and confirm both services run**

```bash
git pull
sudo ./install-kiosk.sh           # re-run; installs menu + touchd, enables them
systemctl status lcd-kiosk-touchd --no-pager   # expect active (running)
```

- [ ] **Step 2: Verify menu summon + persistence**

```bash
lcd-kiosk menu                    # LCD shows the touch menu (shell-triggered path)
# Tap an entry on the LCD -> LCD switches to that app.
lcd-kiosk current                 # reflects the tapped choice
sudo reboot
lcd-kiosk current                 # persisted across reboot
```
Then test the gesture: with an app showing, **press and hold the top-left corner** of the LCD for ~1.5s → the menu should appear.

**Acceptance:** the menu can be summoned (gesture and/or `lcd-kiosk menu`), tapping an entry switches the LCD and persists across reboot, and Connect still works.

- [ ] **Step 3: If the corner-hold gesture is unreliable**

Report `journalctl -u lcd-kiosk-touchd -b --no-pager`. We tune `LCD_TOUCH_CORNER_FRAC` / `LCD_TOUCH_HOLD_SECONDS` (settable via the service environment) or adjust corner logic. The `lcd-kiosk menu` shell path is the guaranteed fallback meanwhile.

---

## Phase 4 — Revert + docs

### Task 15: `LCD-revert` uninstaller

**Files:**
- Create: `LCD-revert`
- Modify: `tests/run-shellcheck.sh` (add target)

- [ ] **Step 1: Write the uninstaller**

Create `LCD-revert`:

```bash
#!/usr/bin/env bash
# Undo the LCD kiosk install: stop/disable services, remove installed files, and
# restore the original /boot/firmware/config.txt from the backup.
set -euo pipefail

CONFIG_TXT="/boot/firmware/config.txt"
backup="$CONFIG_TXT.lcd-safe.bak"

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo ./LCD-revert" >&2
    exit 1
fi

echo "Stopping and disabling services..."
for svc in lcd-kiosk.service lcd-kiosk-touchd.service; do
    systemctl disable --now "$svc" 2>/dev/null || true
done

echo "Removing installed files..."
rm -f /usr/local/bin/lcd-kiosk /usr/local/bin/lcd-kiosk-start \
      /usr/local/bin/lcd-kiosk-menu /usr/local/bin/lcd-kiosk-touchd
rm -rf /usr/local/lib/lcd-kiosk
rm -f /etc/systemd/system/lcd-kiosk.service \
      /etc/systemd/system/lcd-kiosk-touchd.service
rm -rf /etc/systemd/system/lcd-kiosk.service.d
rm -f /etc/X11/lcd-kiosk-fb1.conf
rm -f /etc/sudoers.d/lcd-kiosk
rm -f /etc/udev/rules.d/99-lcd-touch-ignore.rules
rm -rf /opt/lcd-kiosk
echo "(left /etc/lcd-kiosk/kiosk.conf in place; remove manually if desired)"
systemctl daemon-reload || true

if [ -f "$backup" ]; then
    cp -a "$backup" "$CONFIG_TXT"
    echo "Restored $CONFIG_TXT from $backup"
else
    echo "WARNING: no backup ($backup) found; $CONFIG_TXT left as-is." >&2
fi

echo "Revert complete. Reboot to return to the pre-LCD state."
```

- [ ] **Step 2: Lint and syntax-check**

Add `LCD-revert` to `targets` in `tests/run-shellcheck.sh`, then:
```bash
bash tests/run-shellcheck.sh && bash -n LCD-revert && chmod +x LCD-revert && echo OK
```
Expected: `shellcheck: OK (7 files)` then `OK`.

- [ ] **Step 3: Commit**

```bash
git add LCD-revert tests/run-shellcheck.sh
git commit -m "Add LCD-revert uninstaller"
```

---

### Task 16: User documentation

**Files:**
- Create: `docs/lcd-kiosk.md`

- [ ] **Step 1: Write the guide**

Create `docs/lcd-kiosk.md`:

```markdown
# Wayland-safe LCD kiosk (goodtft 3.5″ XPT2046) on Raspberry Pi OS Trixie

This keeps the `labwc`/Wayland desktop (so **Raspberry Pi Connect** keeps working)
and runs a single, swappable kiosk app on the 3.5″ SPI LCD with touch.

## Install

```bash
sudo ./LCD35-show-safe     # Milestone 1: panel + touch (keeps Wayland). Reboots.
sudo ./install-kiosk.sh    # Milestone 2: kiosk app + selectors + touch menu
```

## Choosing what the LCD shows

- Boot default and all changes live in `/etc/lcd-kiosk/kiosk.conf` as
  `KIOSK_DEFAULT`. Add apps by adding `KIOSK_APP_<name>="<command>"` lines.
- Shell: `lcd-kiosk` (interactive), `lcd-kiosk set <name>`, `lcd-kiosk list`,
  `lcd-kiosk current`.
- On the LCD: `lcd-kiosk menu`, or press-and-hold the top-left corner (~1.5s).

Every selection persists as the new boot default.

## Verify

- `ls -l /dev/fb1` — the panel framebuffer exists.
- `sudo evtest` — the `ADS7846 Touchscreen` produces events.
- `rpi-connect doctor` — reports a Wayland compositor.
- `journalctl -u lcd-kiosk -b` — kiosk launcher logs.

## Revert

```bash
sudo ./LCD-revert
sudo reboot
```

## Upgrading to Approach A (all-Wayland DRM) later

The selection layer (`kiosk.conf`, `lcd-kiosk`, the touch menu) is backend-agnostic
and carries over unchanged. To move to an all-Wayland setup, swap two things:

1. **Panel backend:** replace `dtoverlay=tft35a` (fbtft `/dev/fb1`) in
   `LCD35-show-safe` with a DRM panel overlay (`panel-mipi-dbi` + a generated init
   blob) so the panel becomes `/dev/dri/card1`.
2. **Kiosk backend:** replace the X-on-fb1 invocation in `lcd-kiosk-start` with a
   Wayland kiosk (`cage`) bound to the DRM card.

`kiosk.conf` and the selectors do not change.
```

- [ ] **Step 2: Commit**

```bash
git add docs/lcd-kiosk.md
git commit -m "Add LCD kiosk user guide"
```

---

## Final self-checks (run in this environment)

- [ ] **All unit tests pass:** `bats tests/lib.bats tests/cli.bats` → all green.
- [ ] **Lint clean:** `bash tests/run-shellcheck.sh` → `shellcheck: OK (7 files)`.
- [ ] **Push the branch:** `git push -u origin claude/vigilant-sagan-ubm2ub`.
- [ ] **Hand off to the user** for the on-Pi verification tasks (7, 11, 14), which gate each milestone.
