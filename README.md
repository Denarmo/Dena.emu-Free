<p align="center"><img src="docs/branding/icon-512.png" alt="Dena.emu logo" width="128"></p>

# Dena.emu

A multi-system emulator with Delta-style features and a Material You interface,
for Android, Linux handhelds (SD-card OS layer) and iOS. GPL-3.0-or-later.
No ROMs or BIOS files are included or downloaded.

Project brief and rules: [CLAUDE.md](CLAUDE.md). Specs: [docs/specs](docs/specs).

## Layout

| Path | What |
| --- | --- |
| `app/` | Flutter app (shared UI) |
| `host/` | C libretro frontend + headless test harness |
| `cores/` | libretro core build scripts |
| `shells/` | Android, Linux and iOS platform shells |
| `os/` | handheld SD-card image builder |
| `tools/rig/` | hardware-rig scripts |
| `tools/licenses/` | license gate used by CI |

## Build and test

```bash
cmake -S host -B host/build && cmake --build host/build && ctest --test-dir host/build
cd app && flutter test
python -m unittest discover -s tools/rig
python tools/licenses/check_licenses.py
```
