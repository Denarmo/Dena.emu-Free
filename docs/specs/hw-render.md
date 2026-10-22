# Spec: Hardware rendering

Status: draft (Milestone 3, package 4)

N64 (Mupen64Plus-Next) and PSP (PPSSPP) draw with the GPU through the libretro
hardware-render interface. Software cores keep the existing CPU blit.

## Host (`dena/host.h`)

- The platform passes `dena_hw_hooks` (current framebuffer, `get_proc_address`)
  before loading the game. `RETRO_ENVIRONMENT_SET_HW_RENDER` is accepted for
  GLES2, GLES3 and `OPENGLES_VERSION` ≥ 2 only when hooks are set; desktop GL
  and Vulkan are refused, so cores can fall back. `GET_PREFERRED_HW_RENDER`
  answers GLES3.
- A frame passed as `RETRO_HW_FRAME_BUFFER_VALID` is in the framebuffer;
  `dena_core_hw_frame` reports it with its size. Software frames still land in
  `dena_core_frame`.
- The platform calls `dena_core_hw_context_reset` once its context is current,
  and `dena_core_hw_context_destroy` before tearing it down.
- **Core options:** `dena_core_set_option(key, value)` answers
  `GET_VARIABLE`, and a change raises `GET_VARIABLE_UPDATE` once. Keys never
  set answer the default the core declared: the host reports core options
  version 2 and records defaults from `SET_CORE_OPTIONS_V2(_INTL)`,
  `SET_CORE_OPTIONS(_INTL)` (`default_value`, else the first value) and legacy
  `SET_VARIABLES` (first value). A core that sets its own option with
  `SET_VARIABLE` is stored without raising an update. `dena_core_get_option`
  returns what the core would read. Without declared defaults, cores fell back
  to built-in values that broke them (melonDS: no direct boot, so FreeBIOS
  showed a black screen; PPSSPP: internal resolution 0, a 0×0 picture).
- **Dena overrides** (runner, by core library name): melonDS
  `melonds_touch_mode=Touch` (the touch screen is the libretro pointer) and
  `melonds_jit_fast_memory=disabled`.

## Android runner

- If the core asked for GPU rendering, the emulator thread creates an EGL
  display and a GLES 3 context, with a window surface on the game's
  `SurfaceView` (no CPU locking in this mode), and an offscreen framebuffer
  (colour texture, plus a packed depth/stencil buffer when either is
  requested, since PPSSPP asks only for depth but uses stencil) at the
  core's maximum size.
- After each frame the runner draws the framebuffer's used area to the window
  with one textured quad (flipped when `bottom_left_origin`), or through the
  selected shader chain (shaders.md), then swaps.
- Before it draws or reads the framebuffer back, the runner unbinds pixel
  pack/unpack buffers, restores the colour write mask and turns the scissor
  test off: cores leave their own (melonDS, ds.md).
- When the surface goes away the window surface is released but the context
  and framebuffer stay, so the game keeps its GPU state; a new surface gets a
  new window surface.
- Screenshots, slot thumbnails and rewind keep working: screenshots and
  thumbnails read the framebuffer back with `glReadPixels`; rewind only needs
  save states.

## Acceptance tests

- Host (`hw_tests`, test core option `dena_test_hw=enabled`): request accepted
  with hooks and refused without; hooks reached for the framebuffer, proc
  addresses and context reset/destroy; frame size reported; options stored,
  overwritten and length-checked; declared defaults (v2 default, v2 first
  value, legacy first value) answer unset keys and a set value wins.
- Android: the APK builds; the emulator integration test (manual run) shows a
  GPU core's picture. Real-device check is a human step until the rig has one.
