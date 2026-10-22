# Run-ahead (desktop)

Cuts input latency by hiding frames of the game's own input lag: the host
runs the core ahead with save states. Desktop only (Windows, SteamOS);
features-proposal.md "Run-ahead (1–3 frames) and preemptive frames", port
plan phase 5. Free.

## Why

Most games react to a press one or more frames after they read it. The
first desktop pass measured the host at 49–52 ms against the 50 ms gate
(report-desktop-0.1.0.md) without counting that game lag at all. Removing
one frame of it (16.7 ms at 60 fps) brings the estimate well under the gate.

## Modes

Setting **Run-ahead** in Settings > INPUT.CFG (desktop only):
`OFF`, `1`, `2`, `3` frames, and **Method** `PREEMPTIVE` or `RUN-AHEAD`.

- **Preemptive frames** (default). Every frame the host keeps the core's
  state from before each of the last N frames and the input it ran with.
  When the input changes, it loads the state from N frames ago, replays
  those N frames with the new input (muted, not shown) and then runs the
  current frame. Costs one state save per frame, plus N frames and a load
  only on frames where the input changed. Every frame shown is a real one.
- **Run-ahead** (single instance). Every frame: run the real frame (sound
  on), save state, run N more frames with the same input (muted), show the
  last one, load the saved state. Costs N extra frames, a save and a load on
  every frame. Shows a predicted frame (input assumed held).

Second-instance mode (a second copy of the core for the hidden frames) is
not built: the host runs one core per process (host.h, libretro callbacks
are global). Hidden frames are muted and skip the achievements hook and the
RAM mailbox, which covers the side effects that matter here.

## Defaults

- On, **1 frame, preemptive**, for the supported cores below. One frame is
  removed by nearly every game; 2–3 can make some games skip their first
  animation frame and cost more CPU.
- Supported (light enough to run 2–4x and serialize every frame):
  FCEUmm (NES), bsnes (SNES), mGBA (GB/GBC/GBA), fake-08 (PICO-8), Beetle
  PSX (PS1, at most 2 frames). Other cores (N64, DS, PSP, Saturn,
  Dreamcast, GameCube, Wii) run plain whatever the setting says.
- DS stays plain because melonDS's state load is too slow for a replay
  (`runner_tests --costs`, our DS test ROM, cloud x86_64): 6.5 MB state,
  frame 1.7 ms, save 1.9 ms plus 2.1 ms for its size (a full serialize),
  load 22.6 ms with the JIT (it drops the whole JIT cache and rebuilds its
  lookup tables) and still 9 ms with the JIT off (memory timing tables).
  A preemptive replay on an input change would cost more than a frame.
  Getting DS under the gate with run-ahead needs a melonDS change that
  invalidates only the JIT blocks a load really changes.
- Android and the handheld never turn it on (they do not call the setter).

## Rules

- Inputs compared for preemptive replays: every port's digital buttons
  (before turbo) and the pointer press. Analog stick motion does not start
  a replay (it changes almost every frame).
- Off while fast-forwarding, rewinding, paused, or while a deferred state
  load is still retrying. Catch-up frames inside one vsync run plain except
  the last (run-ahead mode).
- The preemptive ring is dropped whenever the core's state changes from
  outside the frame loop: state load, rewind, RAM mailbox writes, cheats,
  starting a game. Nothing replays across that point.
- If the core cannot save or load a state, run-ahead turns itself off for
  that game (plain frames).
- **Sound in run-ahead mode.** Only real frames are heard; hidden frames are
  muted. That is only right for a core whose sound leaves it in the frame
  that made it. mGBA's GB/GBC path (512-sample blocks) and bsnes (one 60 Hz
  frame per block) keep samples in a buffer their save states do not hold,
  so hidden frames leak sound into the real timeline and real sound is
  dropped with them: crackle and underruns (desktop pass 0.1.0-test2, GB/GBC
  at 1 frame). Run-ahead mode therefore runs preemptive on such a core:
  - bsnes is known (`run_ahead_audio_blocks`).
  - Others are found on real frames: after the first sound and 4 settling
    frames, a frame whose sample count is more than a quarter frame away
    from the smoothed count marks the core for that game.
  - Run-ahead mode starts only after 30 real frames (the probe, run
    preemptive), so a block-wise core is found before any hidden frame.
  - Preemptive itself is unchanged; on a block-wise core a replay can move
    its blocks by less than one block, without drift.
  - Metrics: `run_ahead_method` is the method in effect (0 off, 1
    preemptive, 2 run-ahead).
- Achievements (frame hook), the RAM mailbox snapshot and rewind capture
  see only the real timeline: hidden frames skip them.
- Metrics: `run_ahead` in the metrics JSON is the frames in effect (0 when
  off). `tools/rig/desktop_latency.py` subtracts that many frames of game
  lag from its estimate and prints both figures.

## Interface

- Runner: `set_run_ahead(mode, frames)` (any thread; 0 off, 1 preemptive,
  2 run-ahead; frames 1–3), `run_ahead_frames()` in effect.
- Desktop host: `void dena_desktop_set_run_ahead(int32 mode, int32 frames)`
  (dart:ffi), applied at once, also to the running game.
- Dart: `RunAheadSettings` in `desktop_run_ahead.json` in the data folder.

## Acceptance tests

- Unit (host/runner/run_ahead_tests.cpp, fake driver): run-ahead runs
  1 + N frames per shown frame and loads back; preemptive replays N frames
  only on an input change; an invalidated ring replays nothing; a failed
  save turns it off.
- Runner (testcore): with input held from frame 5, run-ahead N shows at
  frame k what plain play shows at k + N (k ≥ 5); preemptive N with the
  press at 5 shows what plain play shows with the press at 5 − N; the true
  timeline (auto-save state) matches plain play in run-ahead mode.
- Unit: a frame-wise fake core keeps run-ahead mode after the probe; a
  block-wise one (512 of 548.6 a frame) falls back before the probe ends
  with no hidden frame; bsnes is known; a new game checks again.
- Runner (testcore): the samples played after every vsync are the same in
  plain play and in both methods at 1, 2 and 3 frames, with presses and
  releases; with `DENA_TEST_AUDIO_BLOCK=512` run-ahead mode reports method 1
  and plays exactly what plain play does with held input.
- Real core (`DENA_CORES_DIR`): mGBA with a GB ROM reports method 1; with a
  GBA ROM method 2, per-frame counts within 8 samples of plain play.
- Dart: settings load/save/defaults and the Settings row.
- Latency tool: `run_ahead` lowers the estimate by that many frames.
