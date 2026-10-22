# Spec: PSP

Status: draft (Milestone 3, package 6)

## Core

- PPSSPP libretro core (GPL-2.0-or-later) at tag `v1.19.3`, built with its
  CMake `LIBRETRO` target by `cores/ppsspp/build.sh` for arm64-v8a and x86_64,
  stripped, and packaged as `libppsspp_libretro.so`. Bundled libraries and
  their licenses are in docs/licenses.md (FFmpeg is the LGPL build).
- Renders through the libretro HW path (docs/specs/hw-render.md, GLES 3).
- Patches in `cores/ppsspp/patches/` (applied by the build script):
  `emu-thread-pause.patch` makes the libretro port's emu-thread pause keep
  running queued render work until the emu thread actually pauses. Upstream
  runs one frame and then waits, which deadlocks when that thread is blocked
  on a GPU sync (framebuffer readback), freezing save, load, resume and pause.
- No rewind: a state is ~40 MB (rewind.md).
- No BIOS or firmware needed (HLE). PPSSPP reads support files from
  `<system>/PPSSPP`: the free replacement system fonts (`flash0/font`), VFPU
  tables, the PPGe atlas used by system dialogs, `compat.ini`,
  `knownfuncs.ini` and English strings. The APK carries them as assets under
  `PPSSPP/` with a `dena-assets.txt` stamp naming the PPSSPP tag; on the first
  start of the PSP core (or after an update changes the stamp) they are
  copied to the system folder. Users who dumped their own PSP fonts can drop
  them into `PPSSPP/flash0/font` themselves. Desktop builds (Windows, Linux) ship the same files in
  `cores/PPSSPP` next to the core, and the host library copies them the same
  way before the PSP core starts.

## Library

- Imports as system `psp` ("PSP"): `.iso` and `.cso`, streamed (large files,
  docs/specs/psx.md import path). `.pbp` stays PlayStation (PS1 EBOOTs);
  PSP EBOOTs and `.chd` PSP discs are a later package.
- Box art: none yet (PSP is in Redump, not No-Intro, and the CRC of a large
  image is not a useful key); games show the placeholder.

## Controls

- RetroPad mapping: △ ○ ✕ □ on X, A, B, Y; L/R; Start/Select; the analog nub
  is the left stick.
- Built-in skin: the PlayStation face layout, L/R shoulders, D-pad with a
  touch analog nub below it (portrait) or beside it (landscape), Start/Select,
  menu.
- Gamepads: analog mode on (sticks pass through, n64.md).
- Cheats: CWCheat `_L 0xAAAAAAAA 0xVVVVVVVV` (the `_L` is optional), stored as
  `0xAAAAAAAA 0xVVVVVVVV`, several lines per cheat.

## Acceptance tests

- Import rules: `.iso`/`.cso` detect as PSP.
- Cheats: CWCheat lines parse and normalise; short values are rejected.
- Golden: built-in PSP skin at phone, 640×480 and 720×720.
- Build: the APK contains `libppsspp_libretro.so` for both ABIs and
  `assets/PPSSPP/dena-assets.txt`.
- On device (human checkpoint, no rig yet): a homebrew PSP game boots, shows
  system-dialog text, and the nub moves the player.
