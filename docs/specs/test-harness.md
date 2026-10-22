# Spec: Emulator test harness

Status: draft (Milestone 0)

## Purpose

Let Claude verify emulator behaviour without a screen or a human: run a libretro core
headless for N frames, hash what it produced, and compare with a recorded golden value.
Covers the three host-level test types in CLAUDE.md §7: golden frames, save-state round
trip and input replay.

## Components (all in `host/`, C11, CMake)

- `dena_host` (library): loads one libretro core with `dlopen`/`LoadLibrary`, implements the
  frontend callbacks, converts frames to a canonical format, hashes video and audio, wraps
  `retro_serialize`/`retro_unserialize`. libretro callbacks are process-global, so one core
  per process.
- `dena-harness` (CLI) built on `dena_host`.
- `dena_testcore` (our own libretro core, no ROM needed). Draws a deterministic pattern that
  depends on the frame counter, a PRNG and input, emits a deterministic tone, and supports
  save states. It exists so CI can exercise the harness with no third-party core or ROM.

## Canonical frame and hashes

- Every video frame is converted to XRGB8888 with the X byte forced to 0, rows packed with
  no pitch padding. Source formats: 0RGB1555, RGB565, XRGB8888 (5/6-bit channels expand by
  bit replication, e.g. `(c << 3) | (c >> 2)`).
- Frame hash: 64-bit FNV-1a over `width` and `height` (32-bit little-endian each), then the
  canonical pixels. Duped frames (`data == NULL`) repeat the previous frame.
- Audio hash: 64-bit FNV-1a over every int16 stereo sample (little-endian) in order, across
  the whole run.
- Output line of a run: `frames=<N> width=<w> height=<h> frame_hash=<16 hex> audio_hash=<16 hex>`
  where `frame_hash` is the hash of the last frame.

## Input replay format (`.dreplay`)

Frame-based so it is deterministic (the rig's time-based format is for real devices).

```
# comment
<frame> <port> <buttons-hex>
```

From `<frame>` (0-based, applied before that frame runs) onward, `<port>` holds exactly the
RetroPad buttons in the mask (bit n = `RETRO_DEVICE_ID_JOYPAD_*` id n). Lines must be in
non-decreasing frame order; ports 0–7 (DENA_MAX_PORTS, eight since the desktop multitap work). Anything else is a parse error with the line number.

## CLI

```
dena-harness run       --core <lib> [--rom <file>] --frames <N> [--replay <f>] [--dump-ppm <out.ppm>]
dena-harness roundtrip --core <lib> [--rom <file>] --frames <N> [--replay <f>] [--after <K=60>] [--strict-state]
dena-harness golden    <manifest> [--cores-dir <d>] [--roms-dir <d>] [--replays-dir <d>]
```

- `run` prints the output line. `--dump-ppm` writes the last frame (for humans).
- `roundtrip`: run N frames; save state S; run K frames → hash A; load S; run K frames →
  hash B; save state S2 right after loading S. Pass iff A == B. With `--strict-state`, S2
  must also equal S byte for byte (our test core); real cores may embed wall-clock data such
  as mGBA's RTC block, so it is reported (`state_bytes=same|differ`) but not required.
- `golden`: manifest lines `name core rom frames replay expected_frame_hash expected_audio_hash`
  with `-` for "no rom" / "no replay". Files are resolved against the given dirs (default:
  manifest directory). A core name without a file extension also matches the platform
  module suffix (`.so`, `.dll`, `.dylib`). A case whose core or ROM file is missing is `SKIP` (ROMs and most cores
  are not in the repo). An expected value of `?` prints the actual value and counts as `NEW`.
  Exit 1 if any case is `FAIL`.

Exit codes: 0 pass, 1 test failure, 2 usage/parse error, 3 core could not be loaded.

## Frontend environment

Handled: `SET_PIXEL_FORMAT`, `GET_CAN_DUPE` (true), `GET_SYSTEM_DIRECTORY` and
`GET_SAVE_DIRECTORY` (a temp dir), `GET_LOG_INTERFACE` (stderr), `SET_SUPPORT_NO_GAME`,
`GET_VARIABLE` (returns no value, so cores use defaults), `GET_VARIABLE_UPDATE` (false).
Everything else returns false. ROMs are loaded into memory and passed with `data`/`size`
unless the core sets `need_fullpath`.

## Acceptance tests (CTest)

- Unit: pixel conversion of known values in all three formats; FNV-1a test vectors; replay
  parser accepts valid files and rejects bad ones with the right line number.
- `testcore` golden: `host/tests/golden/testcore.txt` matches (with and without a replay).
- `testcore` round trip passes, including with input held during the run.
- Determinism: two runs with the same replay give identical hashes; a replay that presses
  buttons gives a different frame hash from no replay.

## Real cores

Golden manifests for real cores live in `host/tests/golden/<system>.txt` and use only
homebrew / public-domain ROMs whose licence is recorded in `docs/licenses.md`. ROM files are
fetched by `host/tests/roms/fetch.sh` (Milestone 1+), never committed unless their licence
allows it.
