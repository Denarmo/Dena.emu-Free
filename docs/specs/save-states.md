# Spec: Save states

Status: draft (Milestone 2, package 5)

## Purpose

Let players save and load the whole machine state at any moment, in numbered
slots with a picture of the game, plus a quick slot for one-button save/load.

## Slots and files (app-private)

- Per game: `states/<sha1>/slot<N>.state` and `slot<N>.png`, N = 1..9.
- Quick slot: `states/<sha1>/quick.state` / `quick.png`.
- The auto-save state (`auto.state`, game-session.md) is separate and never
  shown as a slot.
- The PNG is the last presented frame at the core's native size (no scaling),
  written by the host (`dena_frame_write_png`, uncompressed deflate, no zlib
  dependency). Slot time is the `.state` file's modification time.
- Writes are atomic (temp file, then rename), so a crash never leaves a broken
  slot. Deleting a game deletes its whole `states/<sha1>` folder.

## Native API

- Host: `dena_frame_write_png(frame, path)`; 0 on success.
- Runner (emulator thread, between frames, like `save_now`):
  `save_state(state_path, png_path)` → 0 / -1 and `load_state(state_path)` →
  0 / -1 / `DENA_NO_DATA`. Loading resyncs frame timing.
- `GameHostApi.saveState(statePath, pngPath)` returns an error message or null;
  `GameHostApi.loadState(statePath)` returns an error message or null.

## UI

- Pause sheet gains **Save state** and **Load state**. Each opens a slot sheet:
  a grid of the quick slot and slots 1–9 showing the thumbnail and the time
  ("Empty" otherwise). D-pad moves between slots, A picks, B goes back.
- Save into a used slot overwrites it without asking (the thumbnail makes the
  choice visible); loading an empty slot is not possible (disabled tile).
- After a save or load the game resumes immediately with a snackbar
  ("Saved to slot 3" / "Loaded slot 3"). A load error shows the message and
  stays paused.
- Quick save / quick load from gamepad bindings arrive with the gamepads
  package; the quick slot is reachable from the sheet now.

## Acceptance tests

- Host: PNG writer output decodes (signature, CRCs, Adler-32 and pixels checked
  by a Python test with `zlib`).
- Host: slot round trip through the file helpers (already covered by
  `dena_state_save_file` / `load_file` tests).
- Dart: slot sheet goldens (empty and filled) at the matrix sizes, touch and
  focus modes; saving calls the API with the right paths and resumes; loading an
  empty slot is impossible; a load error keeps the game paused.
