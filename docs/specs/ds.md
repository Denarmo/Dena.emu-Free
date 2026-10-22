# Spec: Nintendo DS

Status: draft (Milestone 3, package 2)

## Core

- melonDS libretro port (GPL-3.0) at a pinned commit, built by
  `cores/melonds/build.sh` for arm64-v8a and x86_64 and packaged as
  `libmelonds_libretro.so`.
- No BIOS or firmware files are needed: the core falls back to its bundled
  FreeBIOS (BSD-2-Clause, credited in docs/licenses.md). If the user puts
  `bios7.bin`, `bios9.bin` and `firmware.bin` in the system folder, the core
  uses them.
- The host answers the core's declared option defaults (hw-render.md), so
  direct boot is on (FreeBIOS cannot boot through the firmware menu). Dena
  sets `melonds_touch_mode=Touch`, turns JIT fast memory off and turns the threaded software renderer on (performance.md).
- Android build fix: bionic's `strerror_r` is the GNU variant; the build
  script patches the bundled Dolphin helper's `#if` to accept `__ANDROID__`.

## Internal resolution

- Auto (default) keeps the threaded software renderer at 256×192 per screen.
  2x / 3x / 4x (shaders.md, Upscale) set `melonds_opengl_renderer=enabled`
  and `melonds_opengl_resolution`, so 3D geometry is rasterised at 2-4× by
  the GPU. 2D layers keep their native pixels, scaled with nearest.
- The Android core is built with melonDS's OpenGL renderer ported to OpenGL
  ES 3.2 (`cores/melonds/patches/gles3.patch`, ours): GLSL 1.40 shaders get a
  GLSL ES 3.00 header and explicit output locations at compile time, implicit
  int-to-float conversions are written out, the 3D palette is repacked to
  RGBA5551 (GLES has no 1_5_5_5_REV), capture readback swaps BGRA in software,
  and buffer maps use `glMapBufferRange`. The core asks for
  `RETRO_HW_CONTEXT_OPENGLES_VERSION` 3.2.
- GLES 3.2 is needed for indexed colour masks. Below it the core keeps
  software 3D and still shows the picture through its GL output, so a 2x-4x
  choice falls back to 1x instead of failing.
- With OpenGL on, the core always outputs 1024×1536 (both screens, 4×); the
  runner's native size stays 256×384 so shaders draw the DS's own lines. The
  core binds its pixel-pack buffer only while it uses it, and the Android
  presenter resets pack/unpack buffers, write masks and scissor before it
  draws or reads back.
- Upstream fixes carried in the patch: the final pass bound attribute names
  the shader doesn't have (`vPosition`/`vTexcoord` vs `pos`/`texcoord`),
  settings changes left framebuffer 0 bound for the frame, the software-frame
  texture was integer but sampled as normalised, and a failed GL renderer
  start crashed instead of falling back.

## Library

- `.nds` imports as system `nds` ("DS"). Box art from the libretro thumbnail
  server, folder "Nintendo - Nintendo DS" (index built from its No-Intro DAT).

## Screen and input

- The core outputs both screens stacked (256×384). The game view keeps that
  aspect; the bottom half is the touch screen.
- **Touch:** a finger on the bottom screen is passed to the core as the libretro
  pointer (`RETRO_DEVICE_POINTER`, coordinates scaled to −0x7fff…0x7fff over
  the whole frame) through `dena_touch_pointer(x, y, pressed)` over dart:ffi.
  Touches on the top screen are ignored.
- **Gamepad:** the right stick moves a pointer cursor on the bottom screen and
  R3 (or the right trigger when the pad has no R3) presses it. Later package.
- Built-in skin: D-pad left, A/B/X/Y right, L/R shoulders, Start/Select and the
  menu button, placed around the stacked screens in portrait; in landscape the
  screens sit side by side with controls on the edges (later package).

## Acceptance tests

- Host: pointer state reaches `retro_input_state` (test core echoes it into
  its frame); unit test for the coordinate mapping.
- `host/tests/roms/nds/make_rom.py` builds `test.nds`: one Gouraud-shaded 3D
  triangle on the top screen, hand-encoded ARM code, no toolchain
  (`nds_rom_up_to_date` checks the committed copy).
- `ds_gles` (host, `DENA_CORES_DIR` with a host core built by
  `MELONDS_HOST_MAKE=GLES=1 cores/melonds/build.sh host`, Mesa GLES): the
  GLES renderer at 1x/2x/4x matches the software renderer's coverage (<1 %
  of pixels), every row of the slanted edge starts on the internal pixel grid
  and, at 2x+, a third or more start between 1x columns; no pixel-pack buffer
  is left bound; with Mesa capped at GLES 3.1 the picture equals software 1x.
- Golden frame and save-state round trip with the DS test ROM: later.
- Dart: `.nds` import; the session maps a touch on the bottom half to pointer
  coordinates and ignores the top half; skin goldens at the matrix sizes.
