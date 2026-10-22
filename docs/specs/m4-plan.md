# Milestone 4 plan: Linux handheld layer

Status: in progress (started 2026-10-16)
Goal (CLAUDE.md §6): boot hooks, power daemon, platform modules, SD image
builder and D-pad polish for H700 (RG35XX / RG40XX), A133P (TrimUI Smart Pro /
Brick) and RK3566 (RG353, Miyoo Flip).
Checkpoint: flash and test each device (needs the hardware and the user's
hands; none is on the rig yet).

## Work packages (one spec each, in this order)

| # | Package | Spec | Testable here |
| --- | --- | --- | --- |
| 1 | Handheld UI: button-hint bar, handheld mode (640×480 / 720×720, no touch), D-pad audit of every screen | handheld-ui.md | yes (widget + golden tests) |
| 2 | Platform modules: per-device profile (evdev map, display, backlight, battery, power key, audio), pure C core with sysfs/evdev parsing | platform-modules.md | yes (host unit tests on parsing and mapping) |
| 3 | Power daemon: sleep/resume, backlight, battery, low-battery and power-key shutdown that flushes saves | power-daemon.md | yes (state machine with fake clock and events) |
| 4 | SD-card layout and image builder: fixed layout, per-device boot hook installer, update-by-file | sd-card.md | yes (Python, builds a layout tree and zip) |
| 5 | Cross toolchain: aarch64 Linux builds of the host, cores and daemon | toolchain-linux.md (draft) | needs a cross compiler on this PC |
| 6 | Flutter embedder: KMS/DRM + GBM + EGL, evdev input, emulator frame as a GLES texture, ALSA audio | embedder.md (draft) | builds with 5; runs only on a device |
| 7 | Single-card image (user, 2026-10-17): own U-Boot, kernel and system, no stock firmware card; H700 first | single-card.md | Linux host or Docker; QEMU boot test |

Packages 1-4 need nothing but this PC. 5 needs a cross compiler (Zig or a
Linux environment); 6 can be written once 5 builds, and verified only on
hardware.

## Defaults chosen (tell the user; easy to change)

- **Firmware versions:** an open question for the user (CLAUDE.md §9). Boot
  hooks are written against each device's documented stock startup script
  layout and marked unverified until a device is on the rig.
- **One process:** launcher = embedder + shared Flutter UI + emulator host.
- **Clean room:** MinUI and SpruceOS are concepts only (CLAUDE.md §4); their
  license terms are still an open question, so nothing here studies their
  code or behaviour beyond their public descriptions.
