# Spec: Shared game runner (`host/runner`)

Status: implemented (Milestone 4, package 6; also what iOS will use in M6).
Tests: `host/runner/runner_tests.cpp` (ctest `runner`).

## Why

The Android shell's `runner.cpp` holds the whole play loop: emulator thread,
pause and auto-save, fast-forward, rewind, save states, cheats, battery
saves, input, audio rate control and latency metrics. Only a few parts are
Android's own (Choreographer, ANativeWindow, Oboe, JNI). The handheld
launcher needs the same loop, and none of it is unit-tested today because it
only builds for Android.

## What moves

`dena::Runner` (C++17, `host/runner/runner.{h,cpp}`) keeps everything that is
not platform API:

- `start(core, rom, system_dir, srm, state)` with the same results
  (error / fresh / resumed / bad state, the `.bad` rename), `stop()`;
- `run_on_emu(fn)` command queue; `pause()` (stop frames, write battery
  save and auto-save state), `resume()`, `save_now()`, `set_speed(1-8)`;
- rewind (`configure_rewind`, `set_rewinding`, L2 hold), save/load state,
  screenshot, cheats, buttons per port, touch mask, analog sticks, pointer;
- `on_vsync(ns)`: runs every core frame due by that vsync (2 ms early,
  resync after 100 ms, at most 3 per vsync, times `speed` when not
  rewinding), presents if any ran, battery save every 30 s when changed;
- audio: resampler and rate control into the ring; the platform reads the
  ring. Muted while fast-forwarding or rewinding;
- metrics JSON (input-to-post, frame interval, missed frames, audio).

The platform supplies a `dena::RunnerPlatform`:

| Hook | Android | Linux handheld |
| --- | --- | --- |
| `wake()` / emulator thread loop and vsync source | ALooper + Choreographer | eventfd + DRM flip time (embedder.md) |
| `open_audio(rate)` → output rate, `pause/start/close_audio`, `xruns()` | Oboe | ALSA |
| `start_gpu(w, h, depth, stencil)`, `hw_framebuffer()`, `proc_address()` | GlPresenter | EGL context shared with Flutter |
| `draw_software(frame)`, `draw_gpu(w, h, origin)`, `read_pixels` | ANativeWindow / GlPresenter | GL texture handed to Flutter |

Shaders stay in the platform's presenter; the runner only passes the path.

## Rules

- Behaviour on Android does not change: the existing instrumentation and
  unit tests, the golden harness and the APK build must pass unchanged.
- The runner never calls platform APIs; one runner per process (libretro
  callbacks are global).

## Acceptance tests (host, `ctest`)

With the test core and a fake platform (manual vsync times, fake audio):

- start fresh, start resumed from an auto-save, bad state renamed `.bad`;
- frames due per vsync at 60 Hz core on 60/90/120 Hz vsync; resync after
  a stall; fast-forward runs `speed` times as many;
- pause writes battery save and state; resume continues;
- rewind steps back and resumes from the captured point; L2 hold;
- save/load state round trip through the runner gives the same frame hash;
- cheats reach the core; audio is muted while fast-forwarding.
