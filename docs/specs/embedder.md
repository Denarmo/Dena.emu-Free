# Spec: Handheld Flutter embedder (`dena-launcher`)

Status: in progress (Milestone 4, package 6). Nothing here runs until a
device is on the rig.

## Progress

| Part | State |
| --- | --- |
| Mode choice, rotation, key ids (`embedder_core.c`) | done, unit-tested |
| `dena-launcher` (`src/launcher/launcher.c`): DRM/GBM/EGL display, page flips, vsync from flip times, platform task runner on the main thread, evdev to Flutter keys (key data plus the raw `flutter/keyevent` message), SIGTERM restores the CRTC | written, cross-builds, passes the ELF check; unrun |
| Profile `rotate = 0/90/180/270` | done, unit-tested |
| Engine library (`libflutter_engine.so`, linux-arm64) | release (AOT): Google publishes the linux-arm64 embedder engine only as a debug (JIT) build and its release GTK library does not export the embedder API, so the release engine and its x64 `gen_snapshot` come prebuilt from `ardera/flutter-engine-binaries-for-arm` (pinned commit and sha256 in `tools/toolchain/flutter-engine.txt`, fetched by `tools/toolchain/flutter_engine.py`). The debug engine stays for development only |
| App bundle | release: `python os/app_aot.py` (Flutter 3.47.7 SDK; gen_snapshot runs on Linux or through WSL) builds `app/build/linux-aot/libapp.so` and the assets; `os/payload.py` ships them as `Dena/data/app/{flutter_assets,lib/libapp.so,icudtl.dat}` without the JIT files. A debug JIT bundle (`flutter build bundle --debug`) still works with the debug engine but compiles the app on the device at every start, so the card's UI starts slowly and runs unoptimised: never ship it |
| Play loop shared with Android (`host/runner`, shared-runner.md) | done, host-tested |
| Games in the launcher (handheld-session.md): Pigeon bridge, frame texture, ALSA audio, vblank pacing, gamepad routing | written, bridge and mailbox host-tested, cross-builds; unrun |
| GPU cores (N64, PSP) in the launcher: GLES 3 context shared with the engine, triple-buffered textures | written, cross-builds; unrun |
| Volume keys (ALSA mixer, handheld-session.md) | written, step and mixer choice unit-tested; unrun |

Usage: `dena-launcher <bundle> [profile.conf]`, where the bundle holds
`flutter_assets/`, `icudtl.dat` and `lib/libapp.so`; the engine library is
`dlopen`ed from the library path and used through
`FlutterEngineGetProcAddresses`. The header is vendored in
`shells/linux/third_party/flutter` (BSD-3-Clause, Flutter 3.47.7's engine).

One process (m4-plan.md): the Flutter engine through its public embedder
API (`flutter_embedder.h`, BSD), our shared Dart UI, and the C emulator host.
The flutter-pi project is a concept reference only (public README); no code
is taken from it, and the source of each concept goes in provenance.md.

## Display (KMS/DRM, GBM, EGL)

- Opens the first DRM card with a connected connector, takes its preferred
  size (640×480, 720×720 or 1280×720 on our devices) at the refresh nearest
  60 Hz, and becomes DRM master. The RG35XX SP's panel prefers a 120 Hz mode;
  the UI and the cores pace to 60, so 120 would only halve each frame's budget.
- Boot log (`Dena/user/boot.log`): the engine kind (release AOT, or a warning
  for a debug JIT engine), at the first frame the time since start, the GL
  renderer and version (a warning for llvmpipe/softpipe, which means the GPU
  is not in use) and the mode, then every 10 s with frames in it the frame
  count and how many missed their vblank while animating (gap over 1.5
  periods and under 250 ms) with the worst gap.
- A GBM surface at that mode backs an EGL window surface (GLES 3 where the
  driver has it, else GLES 2). Flutter gets two contexts: render and
  resource upload, sharing objects.
- `present` locks the GBM front buffer, makes a DRM framebuffer for it
  (cached per buffer) and queues a page flip; the next frame waits for the
  flip event. First frame uses a mode set.
- Vsync: the engine's `vsync_callback` is answered from the page-flip event
  timestamps (refresh from the mode). No busy waiting.
- Rotation: some panels are mounted rotated (the profile's `display.rotate`);
  the embedder applies it as the root transformation, never in Dart.
- On `SIGTERM`, or when the launcher quits, it restores the CRTC it found so
  the stock system draws again.

## Emulator frame

- The emulator host renders the game into a GL texture in the resource
  context (hw-render.md). The embedder registers it as an external texture;
  the session's `Texture` widget shows it. One texture per screen (DS: two).
- Frame done → `FlutterEngineMarkExternalTextureFrameAvailable`; the engine
  composites it on the next vsync. No copies to the CPU.

## Input (evdev)

- Opens every `/dev/input/event*` with keys or absolute axes, maps codes
  through the device profile (platform-modules.md) to RetroPad buttons.
- While a game runs, buttons go straight to the emulator host's input state
  (as on Android, never through Dart). The menu hotkey opens the pause sheet.
- Otherwise buttons become Flutter key events with the gamepad logical keys
  (`gameButtonA`, `arrowUp`...), so the shared UI's focus handling works
  unchanged (handheld-ui.md).
- Hot-plug: inotify on `/dev/input` picks up USB pads.
- Touch panels (RG353V): absolute multitouch becomes Flutter pointer events.

## Audio, power, platform

- Audio: the host's ALSA backend (period from the profile, default 256
  frames at 48 kHz). Volume keys change the mixer, not the stream.
- Power: `PowerLink` (power_link.dart) over the daemon socket.
- The Dart side gets `DENA_HANDHELD=1` and `DENA_CARD`; storage paths come
  from the SD layout (sd-card.md). Platform channels the Android shell
  answers (library import, shortcuts, external display) answer "unsupported"
  here; the UI already hides what a platform lacks.

## Build inputs

- Engine: `libflutter_engine.so` for linux-arm64, release mode, matching the
  app's Flutter version exactly (`os/app_aot.py` refuses another SDK).
- App: the AOT snapshot (`lib/libapp.so`) and `flutter_assets`: the SDK's
  frontend server compiles a product-mode kernel (`--aot --tfa`,
  `dart.vm.product=true`) and the engine's `gen_snapshot`
  (`--snapshot_kind=app-aot-elf`, an x64 Linux tool: WSL on Windows) turns it
  into the ELF (toolchain-linux.md); the embedder itself cross-builds anywhere.
- System headers and libraries: libdrm, gbm, EGL/GLES, ALSA (sysroot).

## Acceptance tests

- Host-buildable parts are pure C (`src/embedder_core.c`) with unit tests
  in `shells/linux/tests/embedder_tests.c`: mode choice (exact size nearest
  60 Hz, else preferred, else largest), rotation transforms and their
  inverse for touch, profile action to Flutter key. The key ids are checked
  against the framework's constants by `app/test/shell/embedder_keys_test.dart`.
- On device (human checkpoint): boots to the library at the panel's native
  mode, 60 fps menus, D-pad navigation, a GBA game at 60 fps with no audio
  crackle, latency under 50 ms (latency-spike.md method), quit returns to
  the stock system.
