# Wayland‑safe LCD + kiosk installer

**Date:** 2026-06-16
**Target hardware:** Raspberry Pi 3 Model B v2, goodtft 3.5″ RPi display (ILI9486 panel, XPT2046 touch controller)
**Target OS:** Raspberry Pi OS, Debian 13.4 "Trixie", 64‑bit (default compositor: `labwc` / Wayland)

## Problem

The upstream `goodtft/LCD-show` installer (`LCD35-show`) makes a working 3.5″ SPI
display show the desktop, but it does so by converting the Pi from a modern
KMS/Wayland desktop into a legacy X11‑on‑SPI‑framebuffer setup. The three actions
that cause the damage are in `LCD35-show` and `system_config.sh`:

1. `system_config.sh:21` — `sudo raspi-config nonint do_wayland W1` forces the
   session to **X11 (Openbox)**, removing the Wayland compositor.
2. The generated `/boot/config.txt` keeps `dtoverlay=vc4-kms-v3d` **commented out**
   (see `boot/config-nomal-12.10-64.txt:26`), disabling KMS.
3. `system_config.sh:20` — `do_boot_behaviour B2` switches to console autologin and
   the desktop is then rendered by X directly onto the SPI framebuffer (`/dev/fb1`)
   via `fbturbo`/`fbcp`.

**Raspberry Pi Connect screen sharing requires a Wayland compositor.** Removing
Wayland is exactly why `rpi-connect doctor` reports "no Wayland compositor" and why
remote screen sharing stops working after running `LCD35-show`.

## Goals

1. Keep the `labwc`/Wayland session intact so **Raspberry Pi Connect keeps working**
   (both screen sharing and remote shell).
2. Bring up the 3.5″ SPI panel and the **XPT2046 touch** input.
3. Run **one swappable full‑screen kiosk app** on the LCD. Chromium is only the
   *reference* app — the kiosk must run **any single command** equally well: a
   browser dashboard, a terminal / text status screen (e.g. `htop` or logs), or a
   specific GUI application. Provide three ways to choose it, all persisting the
   choice as the new boot default:
   1. a **default app on boot**,
   2. a **shell selector command** to change it from an SSH / Connect shell,
   3. an **on‑LCD touch menu** to change it by touch.
4. Structure the work so **Approach A** (DRM panel + Wayland `cage` kiosk) can be
   tried later by swapping two well‑isolated pieces, without a rewrite.

## Non‑goals

- Mirroring the full Wayland desktop onto the LCD.
- GPU‑accelerated rendering on the SPI panel (the SPI link is slow; software
  rendering is acceptable for a dashboard).
- Supporting other panels/boards or other OS versions in this iteration. The
  installer detects and requires Trixie 64‑bit with the `/boot/firmware` layout
  and fails loudly otherwise.

## Core idea: two non‑conflicting display stacks

The two stacks target **different devices** and never contend:

| Stack | Device | Owner | Purpose |
|---|---|---|---|
| Primary (untouched) | KMS card `/dev/dri/card*` | `labwc` (Wayland) | Normal desktop, captured by Connect |
| Secondary (new) | Legacy framebuffer `/dev/fb1` | dedicated mini‑X | The LCD kiosk |

Wayland ignores `/dev/fb1` (not a KMS device), so adding the panel cannot disturb
the session that Connect shares.

## What we deliberately do NOT do (vs. the goodtft script)

- ❌ `raspi-config nonint do_wayland W1` (forces X11) → **keep Wayland.**
- ❌ commenting out `dtoverlay=vc4-kms-v3d` → **keep KMS enabled.**
- ❌ converting the whole desktop to X‑on‑fb1 + console autologin → **keep
  boot‑to‑desktop on Wayland**; run only an isolated kiosk on `/dev/fb1`.

## Architecture & components

New files are added; the upstream scripts are left intact so the change stays
reviewable and the original behavior remains available.

### Panel + touch bring‑up (Milestone 1)

- **`LCD35-show-safe`** — the Milestone‑1 installer. Responsibilities:
  - Detect Trixie + 64‑bit + `/boot/firmware/config.txt`; abort with a clear
    message if assumptions don't hold.
  - Back up current config first (reuse `system_backup.sh`).
  - Install the `tft35a` overlay to `/boot/firmware/overlays/`.
  - Append, **idempotently**, to `/boot/firmware/config.txt`:
    - `dtparam=spi=on`
    - `dtoverlay=tft35a:rotate=90` (panel → `/dev/fb1`)
    - `dtoverlay=ads7846,...` (XPT2046 touch → input event device)
    - **Leave `dtoverlay=vc4-kms-v3d` enabled.**
  - Do **not** call `do_wayland W1`; do **not** change boot behaviour away from the
    Wayland desktop.
  - Install the touch calibration/axis config scoped to the kiosk X server only.
  - Print a verification checklist (see Acceptance).
  - Prompt before rebooting (no surprise auto‑reboot).
  - At this stage the LCD shows the Linux text console.

### Kiosk on the LCD (Milestone 2)

The kiosk is **app‑agnostic**: it runs *any* single command full‑screen on the LCD.
Chromium is only the reference app; a terminal/text‑status screen or a specific GUI
app work identically.

#### Selection model (one source of truth)

`/etc/lcd-kiosk/kiosk.conf` holds two things:

1. A **catalog** of named apps, each mapping a name to an arbitrary command, e.g.:
   - `browser` → `chromium --kiosk <URL>` (Trixie package is `chromium`; `--kiosk`
     for full screen). Default `URL` is a local placeholder page shipped with the
     installer.
   - `status` → a terminal running a text program, e.g. `xterm -fullscreen -e htop`
     (or `tail -F` of a log). Lightest‑weight option.
   - `menu` → the on‑LCD touch menu (see below).
   - the user can add their own named entries for a specific GUI app.
2. A single pointer **`KIOSK_DEFAULT=<name>`** — the currently selected app, which is
   also the **boot default**.

All three interaction surfaces below funnel through this one pointer, so persistence
is automatic and there is a single source of truth. The catalog is open‑ended:
adding an app = adding one `name → command` line; nothing else changes.

#### Components

- **`lcd-kiosk-start.sh`** — the deterministic launcher (single responsibility).
  Reads `KIOSK_DEFAULT`, looks up its command, and runs it in a minimal X server
  bound to `/dev/fb1` (fbdev driver), full‑screen. No interactivity. This is what
  the service calls.
- **`lcd-kiosk.service`** — systemd unit that runs `lcd-kiosk-start.sh`, ordered
  after the graphical session is up, restarts on failure. This provides **(1) the
  default kiosk app on boot**.
- **`/etc/lcd-kiosk/kiosk.conf`** — the catalog + `KIOSK_DEFAULT` described above.
- **`lcd-kiosk`** — **(2) the shell selector command.** Run from an SSH / Connect
  remote shell. Presents a menu of catalog entries (`whiptail` TUI, or a numbered
  list / `lcd-kiosk set <name>` non‑interactive form). On selection it **writes
  `KIOSK_DEFAULT`** (so the choice becomes the new boot default) and restarts the
  service so the LCD switches immediately. `lcd-kiosk menu` switches the LCD to the
  on‑LCD touch menu.
- **On‑LCD touch menu** — **(3) the touch selector.** A small menu rendered on the
  LCD listing the catalog entries; tapping one performs the same "write
  `KIOSK_DEFAULT` + restart" action, so a touch choice also persists across reboot.
  Implemented as a catalog app itself (name `menu`), so it reuses the launcher.
  - **Invocation:** the boards have no physical buttons, so summoning the menu while
    another app fills the screen needs a touch trigger. Design: a lightweight
    background **gesture watcher** (`lcd-kiosk-touchd`) reads the touch event device
    and invokes `lcd-kiosk menu` on a reserved gesture (e.g. a long‑press in a
    screen corner). The shell command `lcd-kiosk menu` is the reliable fallback, and
    `menu` can also be set as `KIOSK_DEFAULT` to make it the home screen.

Because every surface only changes `KIOSK_DEFAULT` and restarts the service, none of
them reimplements launching, and swapping/adding apps never touches the installer or
service.

### Touch routing

`dtoverlay=ads7846` creates an input event device for the XPT2046. The kiosk's
mini‑X server claims it via evdev with an axis/calibration transform. A udev rule /
`labwc` input config makes the main Wayland session **ignore** that device, so the
touchscreen drives the kiosk on the LCD rather than the remote desktop cursor.

The gesture watcher (`lcd-kiosk-touchd`, see touch menu above) needs to observe
touch events even while a kiosk app is running. It reads the same evdev device the
kiosk X server uses; whether it reads in parallel or via the X server is an
implementation detail to settle in the plan (see Open risks). It does not need to
consume events — only detect the summon gesture.

### Revert

- **`LCD-revert`** — restores `/boot/firmware/config.txt` and related files from the
  backup taken by `system_backup.sh`, disables and removes the kiosk service and the
  gesture watcher.

## Groundwork for Approach A (later)

Two backends are isolated behind clear seams so A reuses everything else:

- **Panel backend:** B uses `tft35a` (fbtft → `/dev/fb1`). A swaps to a DRM panel
  overlay (`panel-mipi-dbi` + generated init blob → `/dev/dri/card1`).
- **Kiosk backend:** B uses "X‑on‑fb1". A swaps to "`cage` on the DRM card".
- **Unchanged across both:** the touch overlay + calibration, the `kiosk.conf`
  catalog + `KIOSK_DEFAULT` model, and all three selection surfaces (boot default,
  `lcd-kiosk` shell selector, on‑LCD touch menu). These manipulate the selection
  pointer, not the launch backend, so they carry over to A unchanged.

The installer keeps the panel‑backend and kiosk‑backend choices in separate,
sourced fragments (or a single variable each) so switching to A means editing two
files, not rewriting the installer.

## Milestones & acceptance criteria

### Milestone 1 — foundation ("C")
LCD shows the console, touch events register, Connect still screen‑shares.
**Accept when:**
- Console text is visible on the LCD.
- `evtest` (or `libinput list-devices`) shows the XPT2046 producing events.
- `rpi-connect doctor` is clean and remote screen sharing works.

### Milestone 2 — Approach B
The default kiosk app runs on boot; both selectors can change it (and the change
persists); touch drives the running app; Connect unaffected. Chromium is the
reference app.
**Accept when:**
- On boot, the app named by `KIOSK_DEFAULT` (default: Chromium) fills the LCD.
- Taps land where you touch (calibration correct).
- Remote Connect screen sharing still works.
- `lcd-kiosk` (shell) switches the LCD to another catalog app, and that choice
  survives a reboot — confirming the selector sets the new default.
- The on‑LCD touch menu can be summoned, and tapping an entry switches the LCD to
  that app and likewise persists across reboot.

## Safety & error handling

- Always back up before modifying boot config; provide `LCD-revert`.
- Config edits are **idempotent** — re‑running does not append duplicate lines.
- Detect Trixie + `/boot/firmware` layout; fail loudly if assumptions don't hold.
- **No surprise auto‑reboot** — prompt the user instead.

## Testing strategy

The hardware cannot be exercised from the development environment, so the installer
prints explicit verification commands at each stage and the work proceeds in an
iteration loop: the user runs a milestone on the Pi and reports results (`evtest`
output, `dmesg`/`/dev/fb1` presence, `rpi-connect doctor`, screenshots), and the
scripts are adjusted accordingly.

## Open risks (validated on the Pi)

- `tft35a` must actually create `/dev/fb1` on the Trixie kernel (historically fine;
  verified in M1).
- Input arbitration between `labwc` and the kiosk X server (managed via udev rule +
  labwc input config).
- Chromium under fbdev‑X is software‑rendered → adequate for a dashboard, not fast.
- The primary Wayland output already exists (Connect worked before LCD‑show), so the
  installer must avoid disturbing it.
- **Highest‑risk piece:** the on‑LCD touch‑menu gesture watcher (`lcd-kiosk-touchd`)
  must coexist with the running kiosk app's own touch handling — detecting the
  summon gesture without stealing taps from the app. Reading the evdev device in
  parallel with the X server, or filtering at the right layer, needs validation on
  the Pi. The `lcd-kiosk menu` shell command is the always‑works fallback if the
  gesture proves unreliable.
