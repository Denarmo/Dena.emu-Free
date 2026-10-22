# Spec: Shaders

Status: implemented (Android; handhelds reuse the host renderer in Milestone 4)

Post-processing filters drawn over the game picture: CRT, scanlines, LCD grid,
dot matrix and sharp pixel scaling. The player picks one per system and can
override it per game. All shaders are free (CLAUDE.md §4).

## Shader format

Presets are libretro **GLSL presets** (`.glslp`) and single-file `.glsl`
shaders (one source with `#if defined(VERTEX)` / `#if defined(FRAGMENT)`
halves), the format described in the libretro shader documentation. This lets
the curated set come from the libretro GLSL shader collection under licences
compatible with GPL-3.0.

Supported preset keys (per pass `N`): `shaders`, `shaderN`, `filter_linearN`,
`scale_typeN`, `scale_type_xN`, `scale_type_yN` (`source`, `viewport`,
`absolute`), `scaleN`, `scale_xN`, `scale_yN`, `aliasN`,
`float_framebufferN`, `srgb_framebufferN`, `wrap_modeN`
(`clamp_to_edge`, `clamp_to_border` → edge, `repeat`, `mirrored_repeat`),
`frame_count_modN`, `parameters` with per-parameter values. Lookup textures
(`textures`) and `#include` are **not** supported yet: such a preset fails to
load with a clear error. Slang (`.slangp`) is not supported here; the
Windows and SteamOS desktop has its own slang chain
([shader-stacks.md](shader-stacks.md)).

Defaults when a pass sets no scale: the last pass draws at the viewport, the
others at source size × 1. Filtering defaults to nearest.

Shader sources: `#pragma parameter id "label" default min max [step]` lines
become float uniforms (the line is stripped, `PARAMETER_UNIFORM` is defined),
`VERTEX` or `FRAGMENT` is defined per stage, and a fragment stage without a
`precision` statement gets `precision mediump float;`. A source without a
vertex half uses a stock vertex shader.

Uniforms set per pass (when the shader declares them): `Texture`/`Source`,
`TextureSize`, `InputSize`, `OutputSize`, `OrigTexture`/`Original`,
`OrigTextureSize`, `OrigInputSize`, `PassPrevKTexture`/`Size` (K = 1 is the
previous pass), `<alias>`, `<alias>Size`, `FrameCount` (modulo
`frame_count_mod`), `FrameDirection` (1, or -1 while rewinding), `MVPMatrix`,
`SweepPhase` (0..1 over 8 s, used by CRT bloom) and every parameter.
Attributes: `VertexCoord`, `TexCoord`, `COLOR`.

## Bundled shaders (`host/shaders/<id>/<id>.glslp`)

| Id | Name | Suggested for | Licence |
| --- | --- | --- | --- |
| `sharp-bilinear` | Sharp pixels | any | Public domain |
| `scanlines` | Scanlines | NES, SNES, PSX, N64 | GPL-3.0-or-later (our own) |
| `crt-fast` | CRT (fast) | NES, SNES, PSX, N64, PICO-8 | GPL-2.0-or-later |
| `crt-lottes` | CRT (Lottes) | NES, SNES, PSX | Public domain |
| `crt-easymode` | CRT (EasyMode) | NES, SNES, PSX | GPL |
| `crt-aperture` | CRT (aperture grille) | NES, SNES, PSX | GPL |
| `crt-geom` | CRT (curved) | NES, SNES, PSX, N64 | GPL-2.0-or-later |
| `crt-bloom` | CRT (bloom) | NES, SNES, PSX, N64 | GPL (derivative of EasyMode) |
| `lcd-grid` | LCD grid | GB, GBC, GBA, NDS, PSP | GPL-2.0-or-later |
| `lcd3x` | LCD subpixels | GB, GBC, GBA | Public domain |
| `dot-matrix` | Dot matrix | GB, GBC | Public domain |

The id is the folder name and the preset's base name; the app refers to
shaders by id only. `host/shaders/README.md` keeps authors and licences.

## Renderer (`host/render`, C++ / GLES 3)

- `dena::parse_preset(path)` reads a `.glslp` or `.glsl` into passes and
  parameters (no GL, unit-tested on every host).
- `dena::ShaderChain` compiles a preset in the current GLES 3 context and
  draws a source texture through its passes into a target framebuffer.
  Intermediate framebuffers are reallocated when the source or viewport size
  changes. A float framebuffer that the driver can't render to falls back to
  RGBA8.
- Source convention: texture row 0 is the top of the picture. Output can be
  flipped for window surfaces (bottom-left GL origin).

## Native lines

Shaders that draw scanlines, masks or LCD grids must follow the game's own
lines, whatever size the core hands over and however large the screen is.

- The runner knows each game's native picture size: the core's base geometry,
  or a fixed size for cores whose base geometry is their render size
  (Mupen64Plus-Next 320×240, PPSSPP 480×272).
- `ShaderChain::set_native_size(w, h)`: when a frame is k times that size in
  both directions (k = the largest whole number that fits, 1–8), the chain
  draws it as native: `TextureSize`, `InputSize`, `OrigTextureSize`,
  `OrigInputSize` and source-scaled pass sizes use frame ÷ k. Texture
  coordinates are normalized, so the full-detail frame is still sampled.
- So an N64 game (the core's default is 640×480) gets 240 scanlines, and so
  does the same game at 4×. A frame wider than native in one direction only
  (SNES 512×224 hi-res) is left as it is.
- Viewports that are not a whole multiple of the game (any phone) keep one
  scanline per game line; the last pass always draws at the viewport.

## Upscale (internal resolution)

- Choices: **Auto** (the core's own default), **2x**, **3x**, **4x**,
  through the core's options, set before the game loads
  (`GameHostApi.setUpscale`, then `start`). A change takes effect the next
  time the game starts.
- Supported cores (`kUpscales` in `host/runner/runner.cpp`):

  | System | Core option | 2x / 3x / 4x |
  | --- | --- | --- |
  | N64 | `mupen64plus-43screensize` | 640×480 / 960×720 / 1280×960 |
  | PSP | `ppsspp_internal_resolution` | 960×544 / 1440×816 / 1920×1088 |
  | PSX | `pcsx_rearmed_neon_enhancement_enable` | enabled / — / — (2x at most) |
  | DS | `melonds_opengl_resolution` (+ `melonds_opengl_renderer=enabled`) | 512×384 / 768×576 / 1024×768 per screen |

  DS renders true 3D resolution through melonDS's OpenGL renderer on OpenGL
  ES 3.2 (ds.md, Internal resolution); the note under the choices says so and
  names the requirement. Auto keeps the software renderer.
- **Filter upscale** (GB, GBC): mGBA has no resolution option (it is a
  software renderer). 2x / 3x / 4x instead run
  each frame through the xBRZ pixel-art filter (`host/shaders/_upscale`,
  `xbrz-freescale`) into a picture of that factor × the frame, before the
  shader or the plain (linear) blit. The shader treats that picture as an
  upscaled frame, so it still draws the game's own lines (Native lines). The
  core's frame size, screenshots, thumbnails, rewind and the skin layout are
  unchanged: only the window's picture is smoother. The filter draws through
  GLES like a shader does, from the first frame.
- Every other system (NES, SNES, GBA, PICO-8) draws at its native size only.
  A higher factor is capped to what the system can do (PSX 3x → 2x; GBA 2x →
  Auto). GBA shares GB's core but stays native: the app never sends it a
  factor.
- The Android shell passes the filter's preset path with the factor
  (`nativeSetUpscale(factor, path)`); the runner uses it only when the core
  has no resolution option (`Runner::max_upscale` is 1).
- Shaders still draw the game's native lines when upscaled (Native lines);
  the extra detail is in the sampled picture.
- Windows and SteamOS offer up to 8x (PSX on Beetle PSX HW: 2x, 4x, 8x),
  keep GB/GBC native, and add the cores' widescreen hacks: see
  desktop-resolution.md.

## Android runner

- `setShader(id)` may be called before `start`; the shader then applies from
  the first frame. `""` is Off.
- Software cores keep the CPU blit while no shader has been selected in the
  session. Once one is, they render through GLES: the frame (0x00RRGGBB) is
  uploaded to a texture whose swizzle reads it as RGB, then drawn through the
  chain to the `SurfaceView`. Switching back to Off keeps GLES with a plain
  linear blit.
- A window that the CPU blit has already used can't take an EGL surface, so
  turning a shader on mid-session asks the shell for a fresh surface (the
  `SurfaceView` is hidden and shown again); the game is paused meanwhile, so
  nothing is lost.
- GPU cores (hw-render.md) copy the used framebuffer area into the chain's
  source texture (flipped when `bottom_left_origin`) and draw the chain
  instead of the plain blit.
- Changing the shader while paused redraws the last frame, so the pause sheet
  previews it.
- A shader that fails to load leaves the previous picture path in place and
  returns the error; the app shows "This shader could not be loaded" and
  falls back to Off for the session.
- Screenshots, slot thumbnails and rewind are unaffected: they use the core's
  frame, not the filtered picture.
- Shaders are packaged as APK assets and copied to `files/shaders/` when their
  version stamp changes (as `CoreAssets` does for PPSSPP).
- aapt's default ignore pattern drops asset folders starting with `_`, which
  silently left `_upscale` out of the APK. Both Android modules set
  `androidResources.ignoreAssetsPattern` to the default rules minus `<dir>_*`;
  `app/test/shaders/asset_pattern_test.dart` checks that every folder under
  `host/shaders` survives it.

Latency: the GLES path is measured again with the probe when the rig has a
phone (decision 0001, "Revisit when").

## App

- Per-system default and per-game override, stored in
  `<dataDir>/shaders.json`: `{"systems": {"<system>": "<id>"}, "games":
  {"<sha1>": "<id>"}}`. A game override of `""` means Off for that game even
  when the system has a default. Unknown ids are treated as Off.
- Pause sheet: a **Shader** tile opens a sheet listing Off and every shader
  (suggested ones for the system first, marked "Suggested"), and a choice of
  scope: **This game** or **All <system> games**. Picking a shader applies it
  at once (preview behind the sheet). D-pad operable; B closes.
- Settings: **Shaders** lists each system with its default; tapping one opens
  the same list (system scope only).
- The same sheet (title "Shader and resolution") has a **Resolution** row:
  Auto / 2x / 3x / 4x, saved with the same scope as the shader, in
  `shaders.json` under `"upscale": {"systems": {"<system>": 2}, "games":
  {"<sha1>": 0}}` (0 = Auto). Factors the system can't do are disabled, with
  a one-line note ("<System> draws at its native resolution only", "PlayStation
  renders at 2x at most"); in a game a change shows "The new resolution
  applies the next time the game starts". The settings row's subtitle adds
  "3x resolution" when set. GB, GBC and DS show "Smoothed with the xBRZ
  pixel-art filter".

## Acceptance tests

- Host (`shader_preset_tests`): key parsing, per-axis scale, defaults, quoted
  values and comments, parameter pragmas and overrides, missing pass file and
  unsupported textures are errors, stage preparation.
- Host (`shader_chain_tests`, needs EGL + GLES 3; skipped without them):
  every bundled preset compiles, links and draws with no GL error on a
  256×224 test card into 1024×896; the output is not blank; the passthrough
  preset reproduces the source exactly at 4× nearest; `scanlines` darkens
  between source rows; output flip mirrors rows; resizing the viewport
  reallocates without errors; scanlines show one dark band per game line for
  NES, SNES, GB, GBA at non-integer viewport scales and for N64 (2x, 4x),
  PSP (3x) and PSX (2x) frames given their native size.
- Host (`runner_tests`): `max_upscale` per core (N64 and PSP 4, PSX 2, others 1).
- Host: the `_upscale` preset parses (`shader_preset_tests`) and draws a frame
  at 2x-4x with no GL error and a lit picture (`shader_chain_tests`).
- Dart: store round trip and resolution (game override > system default >
  Off, `""` override), catalog ids match `host/shaders` folders, shader sheet
  goldens at the matrix sizes (touch and focus), picking calls `setShader`
  and saves to the chosen scope, settings list shows each system's default;
  upscale resolution and capping, unsupported factors disabled with the note,
  the stored factor sent with `setUpscale` before `start`.
- Android: the APK builds; real-device check of each shader is a human step
  until the rig has a phone.
