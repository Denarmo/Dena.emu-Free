# Desktop internal resolution and widescreen

Windows and SteamOS only. Feature 1 of the desktop features proposal
(`desktop/features-proposal.md`, "High internal resolution + widescreen
hacks"): render the 3D systems at up to 8x their native size (4K class) and
offer the cores' 16:9 widescreen hacks. Free. Builds on the existing
internal-resolution choice (shaders.md, Upscale), which phones keep at 2x-4x.

## Behaviour

- The shader sheet (pause menu > Shader, and Settings > Shaders > system)
  keeps its `RES` row; on the desktop it offers more factors and a `WIDE`
  row below it. Both rows save with the sheet's `Save` scope (this game or
  every game of the system), like the shader.
- Both are core options read when the game loads: a change made in a running
  game applies the next time it starts, and the note under the row says so.
- Settings > Shaders lists each system's saved factor (`8x`) and `16:9` when
  widescreen is on for the system.

### Factors per system (desktop)

| System | Core (desktop) | Core option | Factors offered |
| --- | --- | --- | --- |
| N64 | Mupen64Plus-Next (GLideN64) | `mupen64plus-43screensize` (`-169screensize` when wide) | Auto, 2x, 3x, 4x, 6x, 8x |
| PSX | Beetle PSX HW | `beetle_psx_hw_internal_resolution` | Auto, 2x, 4x, 8x |
| PSP | PPSSPP | `ppsspp_internal_resolution` | Auto, 2x, 3x, 4x, 6x, 8x |
| DS | melonDS (OpenGL) | `melonds_opengl_resolution` (+ `melonds_opengl_renderer=enabled`) | Auto, 2x, 3x, 4x, 6x, 8x |
| Dreamcast | Flycast | `reicast_internal_resolution` (native 640x480) | Auto (= 2x, 1280x960), 2x, 3x, 4x, 6x, 8x |
| GameCube, Wii | Dolphin | `dolphin_efb_scale` (native 640x528) | Auto (= 2x), 2x, 3x, 4x, 6x, 8x |

- 5x and 7x exist in the cores but are left out to keep the row short; 6x
  covers 1440p screens and 8x covers 4K (N64 2560x1920, PSP 3840x2176, DS
  2048x1536 per screen, PSX 8x).
- Beetle PSX HW at 2x and up also turns on PGXP (`beetle_psx_hw_pgxp_mode =
  memory only`, `beetle_psx_hw_pgxp_texture = enabled`): without it, PS1
  geometry wobbles and textures warp, which shows far more at high
  resolution. Auto keeps the core's defaults (native, PGXP off).
- GB and GBC stay at native size on the desktop: their 2x-4x is the xBRZ
  filter of the Android GLES path, which the desktop slang chain does not
  carry. NES, SNES, GBA and PICO-8 are native everywhere.
- Resolution and shaders are separate: the core renders at the chosen
  factor, then the shader stack (shader-stacks.md) shades that picture at
  the screen's size, drawing the game's native lines (Native lines).
- Phones and the Linux handheld are unchanged (phones: 2x-4x, PSX 2x; the
  handheld launcher draws native only).
- A saved factor the system does not offer rounds down to the nearest
  offered one (PSX 6x → 4x); a factor saved on the desktop is never sent
  above what the core has.
- Dreamcast's Auto is 2x (`1280x960`), set as the core default, since
  640x480 looks soft on any desktop screen (dreamcast-saturn.md). Saturn
  (Beetle Saturn) is a software renderer with no resolution option: no
  `RES` or `WIDE` row.
- PS2 (LRPS2): `RES` Auto, 2x, 4x, 8x on `pcsx2_upscale_multiplier`; a
  factor in between uses the lower one. Auto is 2x, set as the core
  default like Dreamcast (ps2.md).

### Widescreen (desktop)

- `WIDE [OFF] [16:9]`, off by default, for N64, PSX, Dreamcast, PS2,
  GameCube and Wii (the cores with a widescreen hack; PSP is 16:9 already,
  DS and Saturn have none). PS2: `pcsx2_widescreen_hint = enabled (16:9)`,
  LRPS2's per-game widescreen patches; games without a patch stay 4:3.
- N64: `mupen64plus-aspect = 16:9 adjusted` (GLideN64 widens the 3D view) and
  the resolution comes from `mupen64plus-169screensize`. Factor → 16:9 size:
  Auto 960x540 (the core's default), 2x 960x540, 3x 1280x720, 4x 1920x1080,
  6x 2560x1440, 8x 3840x2160.
- PSX: `beetle_psx_hw_widescreen_hack = enabled`,
  `beetle_psx_hw_widescreen_hack_aspect_ratio = 16:9`.
- Dreamcast: `reicast_widescreen_cheats = enabled` (per-game patches, the
  clean result where a game has one) and `reicast_widescreen_hack =
  enabled` (the generic stretch for the rest).
- GameCube and Wii: `dolphin_widescreen = enabled` (the Wii's own 16:9
  setting) and `dolphin_widescreen_hack = enabled` (gamecube-wii.md). Auto
  for both is 2x, set as the core default.
- The game picture (and the save-slot thumbnails, and the external display
  aspect) is drawn at 16:9 instead of 4:3 while widescreen is on.
- The note under the row says it is a hack: "3D games only; 2D art
  stretches".

## Interface

- `GameHostApi.setUpscale(factor)`: 0 = the core's default, 2-8 on the
  desktop. `Runner::upscale_options(core, factor, wide)` maps it through
  `kUpscales` in `host/runner/runner.cpp` (8 values per core, `nullptr`
  where the core has no such factor: the next lower one is used).
- `GameHostApi.setWidescreen(on)`: new, set before `start` like
  `setUpscale`; `Runner::set_widescreen`, applied at the next start through
  `Runner::widescreen_options(core)`. The Android shell accepts it without
  effect (phones never offer it); the handheld launcher and the desktop host
  pass it to the runner.
- Dart: `upscaleFactors(system)` and `hasWidescreen(system)` in
  `shader_store.dart` pick the desktop table when the app runs on the
  desktop shell (`!hasAndroidShell && shellProfile == desktop`); tests pass
  `desktop:` explicitly. `ShaderStore` saves `"widescreen": {"systems":
  {...}, "games": {...}}` (booleans) in `shaders.json` next to `upscale`.

## Acceptance tests

- Runner (host/runner/runner_tests.cpp): desktop core names map 2x/4x/8x to
  the right option values; PSX 3x → 2x, 6x → 4x; PGXP options come with
  PSX 2x+; widescreen gives the N64 aspect + 16:9 size and the PSX hack;
  no widescreen options for PSP, DS or mGBA; Android behaviour unchanged.
- Bridge (shells/linux/tests/bridge_tests.cpp): `setWidescreen` reaches the
  host, a non-bool argument is a bad-args reply.
- Dart: `upscaleFactors` per system for phone and desktop; store round trip
  of widescreen per system and game; game override beats the system;
  unsupported systems resolve to off; the sheet shows the desktop factors
  and the WIDE row only on the desktop; the session sends the factor and
  widescreen before `start` and draws 16:9 when wide.
- Desktop pass (DENA-PC): see `desktop/resolution-widescreen-verify.md` in
  the project files.
