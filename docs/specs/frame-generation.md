# Spec: Frame generation (experimental, Windows and SteamOS)

Status: implemented (desktop only), never run on a real GPU yet. The last
desktop feature of features-proposal.md ("experimental 2x frame
generation", wave 3 of port-plan.md). Free. Phones and the Linux handheld
do not get it.

## What it does

On a screen at least twice as fast as the game (a 120 Hz monitor for a
60 fps game), the host shows one **generated frame between every two real
frames**, so motion looks like 120 fps. The game still runs at its own
speed; only the picture is doubled.

Two looks, picked per system:

- **Interpolate**: a motion-compensated blend (optical flow), the
  "FidelityFX-style" approach of the proposal. Smooth, but scrolling pixel
  art can look slightly soft in the in-between frame.
- **Pixel-art**: the same motion search, but the in-between frame is built
  by **moving whole pixels**: every pixel is copied from the newest frame,
  shifted by a whole number of the game's own pixels (half the motion,
  rounded). No blending, no new colours, so sprites stay crisp; a sprite
  moving an odd number of pixels lands one pixel short of the exact middle.

Off is the default on every system.

## Setting

Settings > VIDEO.CFG > **Frame generation (experimental)**, desktop only
(the row is absent on phones and the handheld). The row's value is
`off` or the number of systems that use it (`2 systems`). It opens a page:

- An `EXPERIMENTAL` sticker and the screen's refresh rate
  (`SCREEN 144 HZ`).
- One row per system (the shader page's systems): `OFF / INTERPOLATE /
  PIXEL-ART`. Stored in `desktop_frame_generation.json` in the data folder
  (`{"modes": {"snes": "pixelArt"}, "fallbacks": {"snes": "..."}}`).
- **Only offered when the screen is fast enough**: a system's choices are
  disabled while the screen runs below 1.98 times its rate (60 fps systems
  need about 119 Hz, so a 119.88 Hz mode counts). With no system offered
  the page shows one log line, `Screen at 60 Hz: needs 120 Hz`. Choices
  already made are kept and apply again once the window is on a fast
  screen.
- Steam Deck OLED (90 Hz) gets the note: "The Steam Deck OLED screen runs
  at up to 90 Hz, under twice 60 fps. Frame generation works on a 120 Hz
  external screen." The LCD Deck gets the same note with 60 Hz.
- A system the latency gate turned off shows the reason under its row
  (Fallback, below) until its choice is changed again.
- Log line: what it does, that it adds one screen refresh of input lag
  (about 8 ms at 120 Hz), and that run-ahead hides more than that.

The session sends the game's system mode to the host before the game
starts (`dena_desktop_set_frame_generation(mode)`, 0 off, 1 interpolate,
2 pixel-art) and sets 0 when the session ends.

## Pipeline (host/render, `frame_gen.h`)

`FrameGen` is a `slang::SourceFilter` (shader-stacks.md, Frame-generation
hook), so it sees every frame between the core and the shader chain's
pass 0, and the chosen shader shades the generated frame like any other.
With no shader picked, the platform loads the passthrough preset
(`shaders/dena/stock.slangp`) at the frame's own size, so the picture
looks as it does with frame generation off (Flutter scales it).

All work is in desktop GL 4.2 fragment shaders on the core's frame (native
or internal resolution), never at the screen size:

1. **Luma**: each new real frame is copied into the filter's own colour
   texture (two, ping-pong: previous and current) and reduced to a luma
   texture at *flow size*: the game's native size (a k-times internal
   resolution frame is box-averaged k×k), else the frame shrunk by a whole
   factor until it is at most 640×480. A half-size luma level is built
   too.
2. **Coarse search** (one fragment per 16×16 block of flow pixels): block
   matching on the half-size level, ±8 half-size pixels (±16 flow pixels),
   sum of absolute differences plus a small penalty per pixel of motion,
   so flat areas keep zero motion.
3. **Fine search** (one fragment per 8×8 block): ±2 flow pixels around
   the coarse vector of its own block and its four neighbours (125
   candidates). Output: motion in flow pixels (from the previous frame to
   the current one) and the match error.
4. **Pick** (one fragment per flow pixel): each pixel tries the vectors of
   the 3×3 fine blocks around it and zero, and keeps the one whose two
   half-way samples (previous frame back by half, current frame forward by
   half) agree best over a 3×3 patch. This is what keeps a sprite's
   background from moving with it.
5. **Synthesis** (one fragment per frame pixel): with the picked vector v
   (in frame pixels):
   - Interpolate: `a = prev(x − v/2)`, `b = cur(x + v/2)` (bilinear);
     where a and b agree the output is their average, where they disagree
     (new content, a scene cut, the match failed) it fades to `b`, the
     newest frame, so nothing ghosts.
   - Pixel-art: `s = round(v/2)` in flow pixels; the output is
     `cur(x + (v − s))` with nearest sampling: the current frame's own
     pixels, shifted by whole game pixels.
6. The chain then shades the result. Generated frames count as frames for
   the shaders' FrameCount and history (animated shaders run at the screen
   rate).

A frame whose size changed, the first frame of a game, frames while
rewinding, fast-forwarding or paused, and repaints are shown as they are
(no generated frame before them). GL timer queries measure the GPU time of
steps 1–5 (`frame_generation_gpu_ms`).

## Timing (host/desktop, `frame_gen_pacer.h`)

Interpolating between frame N−1 and frame N needs frame N, so N is held
back by one screen refresh:

- Vsync with a new real frame N: the generated frame (between N−1 and N)
  is shown at once and N is held.
- Next vsync with no new frame: N is shown. Further vsyncs without a frame
  (a 144 Hz or 240 Hz screen) keep N on screen. Exactly one generated
  frame per real frame ("2x").
- **The generated frame is never shown when the real one is late**: if a
  new real frame arrives while N is still held (the runner caught up two
  frames in one vsync, or the screen is not fast enough), N is dropped and
  the new frame is shown at once, without a generated frame
  (`generated_skipped`).
- Pausing shows the held real frame at the next vsync and nothing more is
  generated. Rewind, fast-forward and a repaint replace the held frame (it
  is dropped, not shown) and nothing is generated from them.
- Below twice the game rate (screen refresh < 1.98 × the core's fps) the
  host does not generate at all (`frame_generation_off: "refresh"`).

## Start-up

The GL set-up frame generation needs (an OpenGL context for a software
core, the stock preset and the filter's programs, all compiled) takes tens
of ms, about 100 ms on some drivers. It runs when the game's video starts,
before the first frame reads input and before `start` returns, never
inside a frame: there it held back the first frame and the input it read
(desktop pass 3: one input ~110 ms late in the first second, 13 to 16
missed frames). Turning frame generation on mid-game, or a refresh change
that allows it, still sets it up at the next frame; that one-off stall is
reported as `frame_generation_setup_ms`.

## Latency gate

Frame generation adds the hold (one refresh) and its GPU time to every
real frame. The host measures that per real frame (`added` = time from
the real frame being ready to it being handed to Flutter, plus the last
measured GPU time) and checks every 60 real frames, over the last 120:

1. **Cost**: p95 `added` must be at most one refresh + 2 ms (10.3 ms at
   120 Hz, 6.2 ms at 240 Hz): the hold is unavoidable, the generation may
   cost 2 ms on top.
2. **Total**: when there are input samples, the same estimate as
   `tools/rig/desktop_latency.py`, `p95 input_to_post + p95 added +
   2 screen refreshes − run_ahead game frames`, must stay under the 50 ms
   target (CLAUDE.md §1) whenever it was under it without frame
   generation. Run-ahead (run-ahead.md) counts: with 1 frame of run-ahead
   the hold is more than paid for.

If either fails, the host turns frame generation off for the rest of the
game (`frame_generation_off: "latency"`, `frame_generation` 0) and shows
real frames only from the next one on. A GL failure (no GL 4.2, a shader
that does not compile) gives `"gl"`.

### Fallback in the app

While a game runs with frame generation on, the session reads
`dena_desktop_frame_generation_status()` every 2 s and once at the end.
When the host turned it off for latency or GL, the app sets that system
back to Off and keeps the reason, shown on the page:

- latency: "Turned off: added 14 ms of input lag (limit 10 ms)".
- gl: "Turned off: this PC's graphics driver can't run it".

"refresh" is not stored (it depends on the screen, not the system): the
setting stays and works again on a fast screen.

## Metrics

Added to the metrics JSON (dena_desktop_metrics and the latency log):

| Field | Meaning |
| --- | --- |
| `frame_generation` | Mode in effect: 0 off, 1 interpolate, 2 pixel-art |
| `frame_generation_want` | Mode the app asked for |
| `frame_generation_off` | Why it is not in effect: `""`, `"refresh"`, `"latency"`, `"gl"` |
| `frame_generation_added_ms` | p50, p95, max of `added` (null when off) |
| `frame_generation_gpu_ms` | p50, p95, max GPU time of a generated frame |
| `generated_frames` | Generated frames shown this game |
| `generated_skipped` | Generated frames skipped because the real one was late |
| `display_hz` | The refresh the host paces by |
| `frame_generation_setup_ms` | Longest GL set-up that ran inside a frame this game (0.0 when it ran before the first frame, see Start-up) |

`tools/rig/desktop_latency.py` adds p95 `frame_generation_added_ms` to its
estimate, counts the two composite frames at `display_hz` when the log
has it, and prints the frame generation line (mode, added, GPU time,
skipped, set-up in game).

## C interface (desktop.h)

- `void dena_desktop_set_frame_generation(int32_t mode)`: any thread; kept
  for a game that starts later; applies from the next frame.
- `const char *dena_desktop_frame_generation_status(void)`: `"<mode in
  effect> <off reason or -> <p95 added ms> <limit ms>"`, e.g.
  `"0 latency 14.2 10.3"`; after a latency fallback the last two are the
  figures that failed. `"0 - 0.0 0.0"` without a session.

## Not done

- No motion vectors from the cores (none of ours export them); everything
  comes from the pictures.
- No extrapolation (showing a predicted frame without holding the real
  one): it would add no lag, but predicted frames go wrong at every
  direction change.
- Games that run at 20 or 30 fps inside a 60 fps core frame (many N64 and
  PS1 games) repeat core frames; frame generation sees no motion between
  the repeats and gains nothing there.
- No FidelityFX source is used: the method is our own (provenance.md),
  so there is no licence row.

## Acceptance tests

- Host, no GL (`frame_gen_pacer_tests`): the 2x cadence at 120 Hz and 144 Hz,
  hold and release, the late-frame skip, pause/rewind/fast-forward release,
  the refresh rule, both gate rules (cost, total with and without
  run-ahead), metrics fields.
- Host, GL through EGL (`frame_gen_tests`, skipped without GL 4.2): a
  square moving 8 px over a textured background lands at +4 px in the
  generated frame with the background unchanged (both modes); pixel-art
  output only holds colours of the current frame and shifts by whole
  native pixels at 3x internal resolution; a scene cut gives the new frame;
  a still picture is reproduced exactly; the chain with a shader shades the
  generated frame; GL state the filter touches is restored.
- Desktop host (`desktop_host_tests`): `set_frame_generation` before a game,
  metrics fields present, status string, refresh fallback at 60 Hz; a game
  started at 120 Hz with frame generation on reports
  `frame_generation_setup_ms` 0.0 (the set-up ran before the first frame),
  turning it on mid-game reports more than 0.
- Dart: settings load/save/default Off, disabled rows below 2x refresh,
  Deck OLED note, fallback stored and shown, cleared on change, D-pad
  operation, golden at 1280x720 and the TV layout.
- Next desktop pass on DENA-PC: `/mnt/project-files/desktop/frame-generation-verify.md`.
