# Spec: Game session

Status: draft (Milestone 2, package 2)

## Purpose

Run any library game in a full-screen session: the right core for its system,
battery saves, auto-save on leaving, resume where you left off, pause, and
fast-forward. Builds on the Milestone 1 runner (SurfaceView path,
docs/decisions/0001-composition-path.md).

## Cores per system

| System | Core library (packaged as) | Notes |
| --- | --- | --- |
| nes | `libfceumm_libretro.so` | cores-m2.md |
| snes | `libbsnes_libretro.so` | performance profile |
| gb, gbc, gba | `libmgba_libretro.so` | |
| genesis | not packaged yet | core choice is the user's (cores-m2.md, Genesis) |

A system whose core is not packaged yet shows "This system's core is not
included in this build" and does not start.

## Files (app-private)

- Battery save: `saves/<sha1>.srm` (the core's `RETRO_MEMORY_SAVE_RAM`).
- Auto-save state: `states/<sha1>/auto.state`, with `auto.png` (the last frame,
  for the library and the pause menu later).
- Deleting a game deletes both (library.md, delete).

## Lifecycle

1. **Start**: load the core and the ROM; if a battery save exists, copy it into
   the core's save RAM before the first frame; if `auto.state` exists, load it
   (resume). A state the core rejects is renamed `auto.state.bad` and the game
   starts fresh, with a snackbar saying so. GPU cores (PPSSPP) refuse states
   until their renderer exists a few frames into the boot, so for them a
   refused state is retried after each frame for up to 600 frames (start
   reports Resumed); only then is it renamed `.bad`. Until it loads, auto-save
   does not overwrite it.
2. **Running**: the session screen is edge-to-edge with no Material chrome; the
   game view keeps its aspect ratio, centred, letterboxed in black.
3. **Pause** (Back, gamepad Start+Select, app goes to background, screen off,
   surface lost): the emulator thread stops running frames, audio pauses, and the
   battery save and auto-save state are written (on the emulator thread, between
   frames).
4. **Resume**: frames and audio continue; frame timing resyncs.
5. **Quit** (from the pause sheet): same writes as pause, then the core unloads and
   the library records play time and `last_played_at`.
6. **Battery saves while running**: written every 30 s if the save RAM changed
   (compared by hash), so a crash loses at most 30 s of in-game saving.

## Fast-forward

Speeds 1×, 2×, 4× (and "unlimited", capped at 8× by frame budget). At N×, the
runner runs N core frames per display frame and presents the last. Audio is
not played while fast-forwarding (the ring buffer is cleared on return to 1×,
so no stale audio plays). Toggled from the pause sheet and by a gamepad
binding (R2 by default).

## Pause sheet (minimal here; full design in pause-menu.md)

A bottom sheet over the paused game: Resume, Fast-forward speed (segmented
1× / 2× / 4×), Quit. D-pad operable; B resumes.

## Native API changes

- `dena_core_set_hashing(core, bool)`: the runner turns off per-sample audio
  hashing (the harness keeps it on).
- `dena_core_memory(core, id, &size)`: the core's memory region (save RAM).
- Runner: `pause()`, `resume()`, `set_speed(n)`, `save_battery(path)`,
  `load_battery(path)`, `save_state(path)`, `load_state(path)`, all executed on
  the emulator thread between frames (queued commands), returning when done.

## Acceptance tests

- Host: battery round trip on the test core's save RAM (byte 0 counts Start
  presses): write, reload, same bytes. Save-state file round trip
  through the new helpers (golden hash equal).
- Native logic (host-side unit tests): fast-forward frame scheduling (N frames
  per vsync, cap), command queue executes between frames.
- Dart: session screen and pause sheet goldens at the matrix sizes; D-pad: B
  opens/closes the sheet, Quit returns to the library and records play time.
- On-device (emulator CI): start the latency ROM, press A, quit, start again:
  the auto-save resumes (frame counter continues, read through `pixel`/metrics).
