# Spec: Shader stacks (Windows and SteamOS)

Status: implemented (desktop only). Feature 9 of the desktop features proposal
(`desktop/features-proposal.md`, "Shader stacks at 4K"): libretro **slang**
presets (`.slangp`) with multi-pass framebuffer chains, lookup textures,
frame history and feedback, drawn at the size the game picture has on screen
(up to 4K and above). Phones and the Linux handheld keep the GLES `.glslp`
chain of [shaders.md](shaders.md) unchanged.

## Presets

Every bundled preset (table below) is free: the CRT, NTSC and scanline
stacks and the simple filters (CLAUDE.md §1).

## Bundled presets (`host/slang-shaders/<id>.slangp`)

The ids match the phone catalog where the look is the same, so a system's
saved choice means the same shader on both. Each `<id>.slangp` is our own
small preset that `#reference`s the upstream preset in the copied tree.

| Id | Name | Passes | Upstream preset (`libretro/slang-shaders`) | Licence |
| --- | --- | --- | --- | --- |
| `sharp-bilinear` | Sharp pixels | 1 | `pixel-art-scaling/sharp-bilinear-simple` | Public domain |
| `scanlines` | Scanlines | 1 | our own (`dena/scanlines.slang`) | GPL-3.0-or-later |
| `crt-fast` | CRT (fast) | 1 | `crt/zfast-crt` | GPL-2.0-or-later |
| `crt-lottes` | CRT (Lottes) | 1 | `crt/crt-lottes-fast` | Public domain |
| `crt-easymode` | CRT (EasyMode) | 1 | `crt/crt-easymode` | GPL |
| `crt-aperture` | CRT (aperture grille) | 1 | `crt/crt-aperture` | GPL |
| `crt-geom` | CRT (curved) | 1 | `crt/crt-geom` | GPL-2.0-or-later |
| `crt-royale` | CRT-Royale | 12 | `crt/crt-royale` | GPL-2.0-or-later; blur passes MIT |
| `crt-guest-advanced` | CRT (Guest advanced) | 12 | `crt/crt-guest-advanced` | GPL-2.0-or-later |
| `gtu` | NTSC TV (GTU) | 3 | `crt/gtu-v050` | GPL-3.0 |
| `lcd-grid` | LCD grid | 1 | `handheld/zfast-lcd` | GPL-2.0-or-later |
| `lcd3x` | LCD subpixels | 1 | `handheld/lcd3x` | Public domain |
| `dot-matrix` | Dot matrix | 1 | `handheld/dot` | Public domain |

- `crt-bloom` (our phone derivative) has no slang version: the desktop list
  leaves it out and a saved `crt-bloom` shows as Off there.
- **ntsc-adaptive is not bundled**: its passes (and guest's `-ntsc` variants
  built on them) carry no licence statement, so they can't be checked
  against the project rule (CLAUDE.md §7). GTU (explicit GPL-3.0) is the free
  NTSC stack. The loader runs ntsc-adaptive fine when the licence is cleared.
- `host/slang-shaders/README.md` lists the copied upstream files, their
  commit and their authors; every source keeps its header.
- Per system, the default is **Off** (as on phones). The sheet marks the
  suggested presets per system first.

## Preset format (host/render, `slang_preset.h`)

Keys (per pass `N`): `shaders`, `shaderN`, `filter_linearN`, `wrap_modeN`
(`clamp_to_border` default, `clamp_to_edge`, `repeat`, `mirrored_repeat`),
`scale_typeN` / `scale_type_xN` / `scale_type_yN` (`source`, `viewport`,
`absolute`, `original`), `scaleN` / `scale_xN` / `scale_yN`, `aliasN`,
`float_framebufferN`, `srgb_framebufferN`, `mipmap_inputN`,
`frame_count_modN`; `textures` with `<name>`, `<name>_linear`,
`<name>_wrap_mode`, `<name>_mipmap`; `parameters` (optional) and
`<parameter id> = value` overrides. `#reference "other.slangp"` loads that
preset first (paths relative to the file that names them, nested up to 16
deep), then this file's keys override it. Values may be quoted; `#` starts a
comment outside quotes.

Defaults: an unscaled last pass draws at the viewport, the others at source
× 1; filtering nearest; RGBA8 targets.

Shader sources (`.slang`, Vulkan GLSL 450): `#include "file"` (relative,
recursive, a cycle is an error), `#pragma stage vertex|fragment` splits the
stages (lines before the first stage go to both), `#pragma name` (an alias
when the preset sets none), `#pragma format <VkFormat>`, `#pragma parameter
id "label" default min max [step]` (first one wins). For desktop GL the
source is rewritten to GLSL 4.20+: `layout(push_constant)` becomes a std140
uniform block, `set = N` is dropped, `gl_VertexIndex` becomes `gl_VertexID`.
Uniform blocks are filled by name through reflection, so their layout can
differ from Vulkan's.

Formats: `float_framebuffer` → RGBA16F, `srgb_framebuffer` → SRGB8_A8, else
`#pragma format` (`R8G8B8A8_UNORM`, `R8G8B8A8_SRGB`,
`A2B10G10R10_UNORM_PACK32`, `R16G16B16A16_SFLOAT`, `R32G32B32A32_SFLOAT`,
`R16_SFLOAT`, `R16G16_SFLOAT`, `R32_SFLOAT`, `R32G32_SFLOAT`, `R8_UNORM`,
`R8G8_UNORM`, `R16_UNORM`, `R16G16_UNORM`, `R16G16B16A16_UNORM`, `R32_UINT`,
`R32_SINT`, `R16_UINT`, `R16_SINT`, `R8_UINT`, `R8_SINT`), else RGBA8. An
unknown format is an error.

## Renderer (host/render, `slang_chain.h`)

- Desktop GL 4.2 or newer (compatibility or core context), functions loaded
  through a `proc_address` callback (WGL on Windows, EGL on Linux). Older GL
  answers "Shader stacks need OpenGL 4.2".
- Every pass renders into its own framebuffer; the last one is the chain's
  output at the viewport size, read by the platform (below).
- Uniforms by name: `MVP`, `OutputSize`, `FinalViewportSize`, `OriginalSize`,
  `SourceSize`, `OriginalHistorySizeK`, `PassOutputSizeK`,
  `PassFeedbackSizeK`, `<alias>Size`, `<alias>FeedbackSize`, `<texture>Size`
  (vec4 w, h, 1/w, 1/h), `FrameCount` (modulo `frame_count_mod`),
  `FrameDirection` (−1 rewinding), `Rotation` (0), `FrameTimeDelta` (µs),
  `OriginalFPS`, `OriginalAspect`, `OriginalAspectRotated`, `TotalSubFrames`
  (1), `CurrentSubFrame` (1) and every parameter. Unknown names are 0.
- Samplers by name: `Original`, `Source`, `OriginalHistoryK`, `PassOutputK`,
  `PassFeedbackK`, `<alias>`, `<alias>Feedback`, `<texture>`. An unknown one
  samples black.
- History: as many past source frames as the passes read
  (`OriginalHistoryK`). Feedback: a pass that is read as feedback keeps last
  frame's output in a second framebuffer.
- Filter, wrap and mipmaps of a pass's output follow the pass that reads it as
  `Source` (the next pass); `Original` and history follow pass 0; lookup
  textures their own keys. `mipmap_input` generates the input's mipmaps.
- The chain saves and restores the GL state it touches (framebuffers,
  program, vertex array, buffers, textures and samplers of the units it uses,
  viewport, enables), because GPU cores share the context.
- Row 0 of every texture is the top of the picture (the source is uploaded
  top-down, GPU frames are flipped while copied); with the Vulkan-style MVP
  the passes see Vulkan's top-left origin.
- **Native lines**: as on phones (shaders.md), the chain is told the game's
  native size. A source k times that size (internal resolution, desktop-
  resolution.md) reports native `OriginalSize`/`SourceSize` for pass 0, so CRT
  stacks draw the game's own lines at 8x too; the full-detail picture is
  still sampled.

### Frame-generation hook

`SlangChain::set_source_filter(SourceFilter *)`: a filter runs between the
core's frame and pass 0, every drawn frame, and may replace the source
texture (and its size) the chain reads as `Original`. The experimental frame
generation feature plugs in here: it receives the core frame (native or
internal resolution), produces the in-between picture, and the chain shades
whatever it hands back, so shaders never see a frame twice and the pause menu
(drawn by Flutter) is never interpolated. With no filter the hook costs
nothing. Frame generation without a shader loads the passthrough preset
`shaders/dena/stock.slangp` so the stage is active
([frame-generation](frame-generation.md)).

## Platform (host/desktop)

- `setShader(id)` → the bridge asks the host for the id's path
  (`GameHost::shader_path`): bundled presets from `<library dir>/shaders/`.
  Before a game starts the
  path is kept and applied after the core loads; in a game it loads on the
  emulator thread at once (and redraws the paused frame, so the sheet
  previews it). A load error leaves the previous picture and returns the
  message; the app then shows "This shader could not be loaded" and turns it
  Off (shaders.md, Android runner, same rule).
- Software cores get a GL context of their own while a shader is on; GPU cores
  share theirs. The core's frame is copied into the chain's source texture
  (flipped for bottom-left GPU frames).
- Output size: the app reports the game picture's size in physical pixels
  (`dena_desktop_set_output_size`), so a 4K screen gets a 3840×2160 chain.
  Until it does, 4× the frame, at most 3840×2160. Capped at 7680×4320.
- Output to Flutter: Windows blits the chain's output into the shared D3D11
  texture (WGL_NV_DX_interop2) or reads it back without it; Linux reads it
  back into the frame mailbox. The Flutter texture then shows it 1:1.
- Screenshots, slot thumbnails and rewind use the core's frame, as on phones.
- Off: the old path (no context for software cores, no copy).

## App

- The shader sheet on the desktop lists Off, the bundled presets (suggested
  for the system first); notes say the pass
  count for stacks ("12 passes"). The sheet opens as the right panel and
  leaves the game undimmed (PR #100), so the pick previews at once.
- Phones and the handheld keep their catalog (shaders.md).

## Acceptance tests

- Host (`slang_preset_tests`, no GL): key parsing and defaults, quoted values
  and comments, `#reference` overrides and relative paths, parameter
  overrides, textures and their keys, `#include` and cycles, stage split,
  `#pragma name/format/parameter`, the GLSL rewrite, every bundled preset
  parses with its pass count (`crt-royale` 12, `crt-guest-advanced` 12,
  `gtu` 3), missing files are errors.
- Host (`slang_chain_tests`, desktop GL through EGL; skipped without it):
  every bundled preset compiles and draws a 256×224 test card into a
  1280×960 output with no GL error and a lit picture; the pass count and
  output size match; a passthrough preset reproduces the source at 4×
  nearest; history and feedback presets see last frame's picture; a lookup
  texture is sampled; `crt-royale` draws a 3840×2160 frame; GL state the
  chain touches is restored; a 4× source with its native size reports native
  sizes; the source filter hook replaces the source.
- Dart: desktop catalog ids match `host/slang-shaders/*.slangp`, phones keep
  the old list.
- Next desktop pass (on DENA-PC): 60 fps at 4K with the heaviest free preset
  per system (`/mnt/project-files/desktop/shader-stacks-verify.md`).
