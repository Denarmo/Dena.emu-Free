# Desktop slang shaders

Shader presets for the Windows and SteamOS builds (docs/specs/shader-stacks.md).
Installed beside the desktop host library as `shaders/`; phones and the Linux
handheld use `host/shaders/` (GLES `.glslp`) instead.

- `<id>.slangp` at the top: our own presets, one per catalog id. Most only
  `#reference` the upstream preset in the tree below.
- `dena/`: our own sources (`scanlines.slang`, `stock.slang`), GPL-3.0-or-later.
- Everything else is copied unmodified from
  [libretro/slang-shaders](https://github.com/libretro/slang-shaders) at
  `e1d75632a205c70f14a4cc947c46d5abb7b3f7f1` (2026-10-08), keeping its paths
  so the upstream presets work as they are. Only the files these presets
  need are copied. One exception: `crt/shaders/guest/advanced/stock.slang`
  (upstream has no licence header) is our `dena/stock.slang`.

Licences are in [docs/licenses.md](../../docs/licenses.md#bundled-slang-shaders-hostslang-shaders-desktop-only).

| Id | Upstream | Authors | Licence |
| --- | --- | --- | --- |
| `sharp-bilinear` | `pixel-art-scaling/sharp-bilinear-simple` | rsn8887 | Public domain |
| `scanlines` | ours | Dena.emu | GPL-3.0-or-later |
| `crt-fast` | `crt/zfast-crt` | Greg Hogan (SoltanGris42) | GPL-2.0-or-later |
| `crt-lottes` | `crt/crt-lottes-fast` | Timothy Lottes, port by the libretro team | Public domain (Unlicense) |
| `crt-easymode` | `crt/crt-easymode` | EasyMode | GPL |
| `crt-aperture` | `crt/crt-aperture` | EasyMode | GPL |
| `crt-geom` | `crt/crt-geom` | cgwg, Themaister, DOLLS | GPL-2.0-or-later |
| `crt-royale` | `crt/crt-royale`, `blurs/shaders/royale`, `include/` | TroggleMonkey | GPL-2.0-or-later; blurs and includes MIT |
| `crt-guest-advanced` | `crt/crt-guest-advanced` | guest(r), Dr. Venom | GPL-2.0-or-later |
| `gtu` | `crt/gtu-v050` | aliaspider | GPLv3 |
| `lcd-grid` | `handheld/zfast-lcd` | Greg Hogan (SoltanGris42) | GPL-2.0-or-later |
| `lcd3x` | `handheld/lcd3x` | Gigaherz | Public domain |
| `dot-matrix` | `handheld/dot` | Themaister | Public domain |

To add a preset: check every file's licence first and add the row to
docs/licenses.md, copy the files with their upstream paths, add `<id>.slangp`,
then the catalog entry (`app/lib/src/shaders/shader_catalog.dart`) and the
pass count the host test expects (`host/render/tests/slang_preset_tests.cpp`).
