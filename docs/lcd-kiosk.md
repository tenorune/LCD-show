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

- `cat /sys/class/graphics/fb*/name` — one entry is `fb_ili9486` (the panel; it
  may be `/dev/fb0` on a headless Pi or `/dev/fb1` with HDMI attached — the kiosk
  finds it by name, so the number does not matter).
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
