# Spec: Desktop shell (Windows and Linux PCs, Steam Deck)

Status: implemented in code (thread "Desktop shell foundation"); the first
build and run on DENA-PC happens in the combined desktop test pass. Plan:
the project's desktop port plan (Windows 10/11 x86_64, Linux x86_64 with
SteamOS 3 first).

## What it does

The same Flutter app runs on the stock Flutter **Windows** runner
(`app/windows`) and **Linux GTK** runner (`app/linux`). Games run in the
**desktop host library**, `dena_host.dll` / `libdena_host.so`
(`host/desktop`): the shared `dena::Runner` with a desktop
`RunnerPlatform` built on SDL3. The runners load the library at run time
and connect it to Flutter; the Dart session code is the same as on Android
and the handheld. No UI changes: the desktop uses the shared UI as it is.

## Pieces

### Host library (`host/desktop`)

- C interface `include/dena/desktop.h`; the runners load it with
  `include/dena/desktop_loader.h` (LoadLibrary / dlopen with RTLD_GLOBAL),
  so a build without the library still opens the UI, and on Windows the
  library can be built with MinGW-w64 while the runner is built with MSVC.
- `dena_desktop_init(cfg)` takes callbacks for "frame ready" (any thread)
  and "send this Pigeon message to Dart" (any thread; the runner copies it
  and sends it from the platform thread), the top-level HWND (Windows) and
  the display refresh in mHz.
- `dena_desktop_channels()` lists the 18 `GameHostApi` channels; the
  runners answer each with `dena_desktop_message`, which is the handheld's
  `GameBridge` (handheld-session.md, Game bridge) over a desktop
  `GameHost`. Differences from the handheld:
  - Cores: the app's Android name (`libmgba_libretro.so`) becomes
    `mgba_libretro.dll` / `mgba_libretro.so` (PS1: Beetle PSX HW,
    `mednafen_psx_hw_libretro`, from docs/dev/desktop-cores.md), looked up in
    `<root>/cores/`, then in `cores/` next to the library; else left to the
    library search path (the start then fails with the runner's message).
  - BIOS in `<root>/Bios`, screenshots in `<root>/Screenshots`.
  - `setShader` loads the desktop's slang presets (`shaders/<id>.slangp`
    beside the library) into the multi-pass desktop GL chain ([shader-stacks.md](shader-stacks.md)).
- Events to Dart: `onMenuRequested`, `onPlayersChanged` (names per port at
  every hotplug), `onControllerDisconnected` (while a game is loaded) and
  `onGamepadUsed` (first pad or key press after touch input).
- dart:ffi exports with the same names as `libdena_android.so`:
  `dena_touch_buttons`, `dena_touch_pointer`, `dena_touch_analog`,
  `dena_set_turbo`, `dena_rewind_hold`, `dena_rewind_budget`/`_info`/`_scrub*` (rewind.md, Long rewind), `dena_ram_*`, `dena_ra_*`,
  `dena_link_*` (the Windows link cable is the existing stub), plus
  `dena_desktop_texture`, `dena_desktop_set_root`, `dena_desktop_gamepads`,
  `dena_desktop_metrics`, `dena_desktop_latency_log` and
  `dena_desktop_set_run_ahead` ([run-ahead](run-ahead.md)),
  `dena_desktop_set_frame_generation` and
  `dena_desktop_frame_generation_status`
  ([frame-generation](frame-generation.md)).

### Controllers

- SDL3 on its own thread (no SDL window; background events on, so pads
  work while the Flutter window has focus; on Windows raw input on SDL's
  joystick thread). Pads are polled every 1 ms.
- Hotplug: each pad takes the lowest free port 0-3 in connection order; a
  fifth waits and takes the first port that frees up. Unplugging releases
  that port's buttons and sticks.
- Mapping is positional, as on Android: bottom face button RetroPad B,
  right A, left Y, top X; Back = Select; shoulders L/R; triggers L2/R2 past
  12000 of 32767; stick clicks L3/R3; sticks to the port's analog.
- Guide, or Start + Select, opens the pause menu once per press and lets
  every button go. While no game is playing (library, pause menu) pad
  events do not reach the game; they drive the UI instead
  (`dena_desktop_set_ui_input`, [controller-mode.md](controller-mode.md)).
  `dena_desktop_gamepads` gives the count for the fullscreen-at-launch rule.

### Keyboard

The keyboard is one more device on port 0 (ORed with port 0's pad). The
runners pass each key press and release to `dena_desktop_key` before
Flutter sees it (Windows: in the message loop, because keys go to
Flutter's child window; Linux: the window's key signals). While a game
plays, bound keys are the game's; otherwise every key is Flutter's. A
release goes wherever its press went, and auto-repeat follows the first
press, so Flutter never sees a release without its press.

Bindings (RetroArch's defaults): arrows = D-pad, X = A, Z = B, S = X,
A = Y, Q/W = L/R, Enter = Start, right Shift or Backspace = Select,
Escape = pause menu, R held = rewind (rewind.md). Remapping is the profiles feature.

### Video

- Software cores: frames go straight to the texture.
- GPU cores (hw-render.md): a hidden desktop GL context of the library's
  own, compatibility profile 4.6 down to 3.3 (WGL on Windows; EGL with the
  default display, else Mesa's surfaceless platform, on Linux). The host
  accepts `RETRO_HW_CONTEXT_OPENGL` and `OPENGL_CORE` there instead of
  GLES (`dena_set_desktop_gl`), and prefers `OPENGL_CORE`.
- **Windows:** the runner registers a `GpuSurfaceTexture` with a DXGI
  shared handle. The library owns a D3D11 device on the default adapter
  and three B8G8R8A8 shared textures (triple-buffered as on the handheld).
  Software frames are uploaded with `UpdateSubresource`; GPU frames are
  blitted from the core's framebuffer into the texture through
  `WGL_NV_DX_interop2` (no copy through the CPU). Without that extension
  GPU frames are read back and uploaded.
- **Linux:** the runner registers an `FlPixelBufferTexture`; software
  frames go through the handheld's `FrameMailbox`, GPU frames are read back
  first. A zero-copy `FlTextureGL` path with a context shared with GDK's
  comes after the latency measurement says it is needed.
- The texture id reaches Dart through `dena_desktop_texture`; the game
  view is `Texture(textureId: id, filterQuality: none)`.

### Vsync

- Windows: the emulator thread waits for the vblank of the monitor the
  window is on (`IDXGIOutput::WaitForVBlank`, output re-checked every 120
  frames). If it returns at once five times in a row (display asleep), the
  clock paces the next 120 frames.
- Linux: the clock at the monitor's refresh rate (GDK, updated when the
  window moves). Wayland presentation feedback is a follow-up.
- Either way the runner's deadlines keep the game at its own speed on 120,
  144 Hz or VRR displays (latency-spike.md, Timing).

### Audio

SDL3 audio stream, S16 stereo 48 kHz, 256-frame device periods requested
(WASAPI shared mode on Windows, PipeWire / PulseAudio / ALSA on Linux,
whichever SDL finds). SDL's callback reads exactly what the device asks
for from the runner's ring; the ring's target is the audio latency setting
(performance.md). Without an audio device games run silent.
`dena_desktop_chime` mixes the RetroAchievements unlock chime (0.3 s) into
that stream when the overlay's sound is on ([achievements.md](achievements.md)).

### Storage

| Where | Root | App data |
| --- | --- | --- |
| Windows | `%APPDATA%\Dena.emu` | the root |
| Flatpak (`FLATPAK_ID`) | `$XDG_DATA_HOME` (= `~/.var/app/<id>/data`) | the root |
| Other Linux | `$XDG_DATA_HOME/dena.emu`, else `~/.local/share/dena.emu` | the root |
| Portable: `portable.txt` beside the executable | `<exe dir>/Dena` | `Dena/user/data` (sd-card.md layout) |

App data holds the library database and every store (`appDataDir`,
`libraryDatabaseDir`). The root also holds `Bios/`, `Screenshots/`,
`cores/` (cores the user adds) and `logs/`; Dart passes it to the library
with `dena_desktop_set_root` at start-up. The Windows executable's manifest
sets the UTF-8 code page, so non-ASCII paths reach the library and cores.

### Profiles (Dart)

`detectShellProfile()`: `android`, `handheld` (Linux with
`DENA_HANDHELD=1`), `desktop` (Windows, other Linux) or `none`.
`openHostLibrary()` opens the profile's library for every dart:ffi user
(touch, turbo, RAM mailbox, achievements, link cable).

### Latency

An empty `latency` file in the storage root, or `DENA_LATENCY_LOG=1`,
makes the library append one runner metrics line per second while a game
plays to `<root>/logs/latency.jsonl` (`{"t_ms": ..., "input_to_post_ms":
..., "frame_interval_ms": ..., "audio_underruns": ...}`; fields as in
latency-spike.md). `python tools/rig/desktop_latency.py <log>` prints the
worst p95 input-to-post plus two frames for Flutter to composite against
the 50 ms gate. Input timestamps come from SDL (pads) and the key handler
(keyboard), on the runner's clock.

Without a window or the app, `runner_tests --latency <core> <rom> <dir>
<run-ahead mode> <frames> <seconds>` plays a real core in real time (60 Hz
vsyncs, A flipped every ~250 ms) and writes the same `<dir>/latency.jsonl`;
`runner_tests --costs <core> <rom> <n>` prints one frame's and one state
save/load's median cost (`DENA_BENCH_OPTIONS="key=value;..."` sets core
options). ctest `ds_latency` runs the first on melonDS with our DS test ROM
when `DENA_CORES_DIR` has the core.

**Fallback if the texture path misses the gate:** a native fullscreen game
window owned by the library (SDL window or plain Win32 / Wayland surface,
presented directly with vsync), with the pause menu and overlays as a
transparent Flutter window above it. Not built; only if measurements on
DENA-PC show the texture path cannot reach 50 ms.

## Building

See `host/desktop/README.md`. The library builds in WSL2 Debian on
DENA-PC: natively for Linux, with MinGW-w64 for Windows. The Flutter
Windows runner needs Visual Studio 2022 (Desktop C++ workload) on Windows
itself. `app/windows/CMakeLists.txt` and `app/linux/CMakeLists.txt` copy
the library from `build/desktop-win64` / `build/desktop-linux` and the
cores from `cores/build/win64` / `cores/build/linux-x86_64` into the
bundle when they exist.

## Edge cases

- Library missing or failing to start: the UI runs, `Texture(-1)` shows
  nothing and every game start fails with the core-not-found message.
- No GPU (headless, VM without GL): software cores still run on Linux; on
  Windows no D3D11 device means no picture (logged).
- A pad unplugged mid-game: buttons released, `onControllerDisconnected`
  (the session pauses).
- Window moved to another monitor: Windows follows that monitor's vblank
  within 120 frames; Linux takes the new refresh rate at once.

## Acceptance tests

- `host/desktop/tests/desktop_map_tests.cpp`: pad and key bindings, menu
  combos, port assignment with a waiting fifth pad, core names and search
  order, Pigeon event payloads, latency log lines.
- `host/desktop/tests/desktop_host_tests.cpp`: loads the built library the
  way the runners do, starts our testcore by a Pigeon `start` message,
  checks frames arrive on the texture (RGBA, opaque), keys taken only
  while playing, Escape sends the menu event, releases follow presses
  across a pause, metrics JSON, and the dart:ffi exports.
- Dart: `test/shell/desktop_platform_test.dart` (profiles, library paths,
  storage roots including portable mode and Flatpak) and
  `test/session/game_view_test.dart`.
- `tools/rig/test_desktop_latency.py`: the gate estimate.
- On DENA-PC (combined desktop test pass): the checklist in the thread's
  final reply.
