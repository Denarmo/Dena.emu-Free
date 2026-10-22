# Bundled shaders

libretro GLSL presets drawn over the game picture (spec:
[docs/specs/shaders.md](../../docs/specs/shaders.md)). Each folder is one
shader: `<id>/<id>.glslp` plus its passes in `<id>/shaders/`. The app refers to
shaders by id only.

All of them are free. They come from the libretro GLSL shader collection
(`libretro/glsl-shaders`), as packaged in the Cannelloni emulator
(`Denarmo/Cannelloni`, `app/src/main/assets/shaders`), except `scanlines`,
which is our own. Each source keeps its original header; the GPL-2.0-or-later
and unversioned GPL ones are distributed here under GPL-3.0-or-later, which
both permit.

| Id | Source | Author | Licence |
| --- | --- | --- | --- |
| `sharp-bilinear` | `sharp-bilinear-simple` | rsn8887, based on Themaister | Public domain |
| `scanlines` | our own | Dena.emu | GPL-3.0-or-later |
| `crt-fast` | `zfast-crt` | Greg Hogan (SoltanGris42) | GPL-2.0-or-later |
| `crt-lottes` | `crt-lottes-fast` | Timothy Lottes, adapted by hunterk | Public domain |
| `crt-easymode` | `crt-easymode` | EasyMode | GPL (any version) |
| `crt-aperture` | `crt-aperture` | EasyMode | GPL (any version) |
| `crt-geom` | `crt-geom` | cgwg, Themaister and DOLLS | GPL-2.0-or-later |
| `crt-bloom` | Cannelloni `crt-cannelloni` (Kawase blur + composite) | Denarmo; CRT base by EasyMode | GPL (derivative of crt-easymode) |
| `lcd-grid` | `zfast-lcd` | Greg Hogan (SoltanGris42) | GPL-2.0-or-later |
| `lcd3x` | `lcd3x` | Gigaherz | Public domain |
| `dot-matrix` | `dot` | Themaister | Public domain |
| `_upscale` (not a user shader) | `xbrz/xbrz-freescale` | Hyllian (MIT), xBRZ by Zenju (GPL-3.0) | GPL-3.0 |

`_upscale` is the filter behind 2x-4x resolution on GB, GBC and DS
(shaders.md, Upscale). Folders starting with `_` are not in the app's catalog
and can't be picked as a shader. aapt skips `_` folders by default, so both
Android modules override `ignoreAssetsPattern` to package them (shaders.md).

Adding a shader: copy the preset folder here under a new id, record its author
and licence (GPL-3.0 compatible only) in this table and in
`docs/licenses.md`, add it to the app's catalog
(`app/lib/src/shaders/shader_catalog.dart`) and to the id lists in
`host/render/tests/`. Lookup textures and `#include` are not supported yet.
