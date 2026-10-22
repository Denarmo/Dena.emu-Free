# Emulation performance

Goal (CLAUDE.md §1): stable 60 fps, input-to-photon under 50 ms, no audio crackle.

## Emulator thread scheduling (Android)

- The emulator thread (Choreographer-paced, `shells/android/.../runner.cpp`) sets
  its nice value to -10 at start, above normal app threads and equal to
  display-urgent work, so GC, decoding and sync work cannot delay a frame.
  Failure is logged and ignored.
- On API 33+ it opens an ADPF performance-hint session (`APerformanceHint_*`,
  resolved with `dlsym`; minSdk is 26) with a 16.67 ms target and reports the
  wall time of each vsync's work (`Runner::on_vsync`). The governor then
  raises clocks before frames are missed. Older devices skip this silently.
- The session closes when the emulator thread ends.

## Measuring

## Audio latency

Settings → Playback → Audio latency: 40 ms (Normal, default), 30 ms (Low),
20 ms (Lowest, may crackle). The runner clamps 20..80 ms and applies it when
audio opens at game start (`Runner::set_audio_latency_ms`). On Linux
handhelds the ALSA hardware buffer adds about half the setting on top
(handheld-session.md, Audio).

Device numbers (frame time p50/p99, dropped frames) come from the rig
(`tools/rig`) via `dumpsys gfxinfo` / the runner's frame stats; host numbers
from `dena-harness run` wall time per frame.

## Core compiler flags

Android cores built through `cores/libretro-make.sh` (FCEUmm, bsnes, melonDS,
PCSX ReARMed, fake-08) use `APP_OPTIM=release` and `-O3` instead of
ndk-build's default `-O2`. `ANDROID_OPT` overrides it (`ANDROID_OPT=-O2` to
compare). NEON is already on for arm64-v8a. LTO is left off until the
integrated phone pass shows the `-O3` result; mGBA and PPSSPP build with
CMake `Release` and are unchanged.

## DS (melonDS)

The 0.0.8 phone pass measured 43-51 fps on the Pokemon SoulSilver title at
73-80 % CPU (report-v0.0.8). The Android melonDS build has the ARM64 JIT on
(core default) but no OpenGL renderer, so the 3D software rasteriser ran on
the emulator thread. Dena now sets `melonds_threaded_renderer=enabled`, which
moves it to a second core. JIT branch and literal optimisations are already on
by default; fast memory stays off (ds.md).

Verify in the next combined pass: SoulSilver title for 60 s with SurfaceFlinger
timestats. Pass is >= 59 fps average and no new graphics glitches against 0.0.8
(compare a screenshot of the title and an overworld scene). If it is still
short, the next steps are a frame-skip option for DS and turning the OpenGL
ES renderer on at 1x for 3D-heavy games.

2x-4x DS (ds.md, Internal resolution) moves 3D to the GPU through melonDS's
OpenGL renderer on GLES 3.2, which also takes the 3D rasteriser off the CPU.
Its cost is the extra GPU fill and the per-frame texture uploads (VRAM and
palette, plus the 2D layers for the compositor). Measure in the combined pass
at each factor: SoulSilver title and an overworld scene for 60 s, fps average
and CPU %. Pass is >= 59 fps at 2x; 3x and 4x are reported, not gated.
