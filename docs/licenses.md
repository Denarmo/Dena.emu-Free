# Licenses

Dena.emu is licensed under **GPL-3.0-or-later** (see [LICENSE](../LICENSE)).

Every dependency gets a row here before it is merged. CI runs
`tools/licenses/check_licenses.py`, which fails when a Dart package or a
`host/third_party/` directory has no row, when a package's LICENSE file does not
match the row, or when a banned project (CLAUDE.md §3) appears in code or build
files. Licenses must permit commercial use and be GPL-3.0 compatible.

## Vendored code (`host/third_party/`)

| Name | License | Source | Notes |
| --- | --- | --- | --- |
| `rcheevos` | MIT | `RetroAchievements/rcheevos` tag `v12.5.0` | RetroAchievements client (achievements.md); one local patch, see its README |
| SDL3 (`host/desktop`, static in `dena_host.dll` / `libdena_host.so`) | Zlib | `libsdl-org/SDL` release `3.2.24` (pinned sha256 in `host/desktop/CMakeLists.txt`) | Desktop gamepads, audio (desktop-shell.md); on the licence page in desktop builds |
| `stb` | MIT (or public domain, either) | `stb_image.h` from `nothings/stb` v2.30 @ `f58f558c120e9b32c217290b80bad1a0729fbb2c` | PNG lookup textures of desktop shader presets (shader-stacks.md), PNG only |
| `khronos` | MIT | Khronos GL headers `GL/glext.h`, `KHR/khrplatform.h` from `KhronosGroup/OpenGL-Registry` @ `6af574a1`, `KhronosGroup/EGL-Registry` @ `db3425b8` | GL types and enums for the desktop slang chain (MSVC has no `glext.h`); headers only |
| `libretro` | MIT | `libretro/libretro-common` `include/libretro.h` @ `a3194c18ba65ef89734e1898a2f61403c255d368` | libretro API header only |
| Flutter embedder API (`shells/linux/third_party/flutter/embedder.h`) | BSD-3-Clause | Flutter SDK 3.47.7, engine `deb287481e3ce9468f3434937ced4240a70539ca` | Header only, for `dena-launcher` |
| Flutter engine, linux-arm64 embedder (`libflutter_engine.so`, release) and `gen_snapshot` (build time only) | BSD-3-Clause (engine) plus the third-party notices of `sky_engine/LICENSE` | Prebuilt from the unmodified engine source by `ardera/flutter-engine-binaries-for-arm` (repo MIT), tag `engine_deb287481e3ce9468f3434937ced4240a70539ca` (`tools/toolchain/flutter-engine.txt`, pinned commit and sha256) | Not in git; `tools/toolchain/flutter_engine.py` fetches it, `os/payload.py` ships the engine as Android ships `libflutter.so`. Google publishes no release embedder for linux-arm64 |
| Flutter engine, linux-arm64 embedder (`libflutter_engine.so`, debug, development only) | BSD-3-Clause (engine) plus the third-party notices of `sky_engine/LICENSE` | Google `flutter_infra_release`, engine `deb287481e3ce9468f3434937ced4240a70539ca` (`tools/toolchain/flutter-engine.txt`, pinned sha256) | Not in git; `os/payload.py` copies it into the handheld payload, as Android ships `libflutter.so` |
| Roboto font (`app/assets/fonts/roboto/`) | OFL-1.1 | `google/fonts` `ofl/roboto/Roboto[wdth,wght].ttf` (main, 2026-10-17); static 400/500/600/700 instances cut with fontTools `varLib.instancer` | The app font on every platform; Linux handhelds have no system fonts. Licence text in `OFL.txt` and on the licence page |
| IBM Plex Mono font (`app/assets/fonts/ibm_plex_mono/`) | OFL-1.1 (Reserved Font Name "Plex") | npm `@ibm/plex-mono` 2.5.0 (IBM's official package), `fonts/complete/woff2` Medium/SemiBold/Bold, unwrapped to TTF with fontTools (outlines and names unchanged) | The Brutalist UI face for every functional text (brutalist-ui.md). Licence text in `OFL.txt` and on the licence page |
| Archivo Black font (`app/assets/fonts/archivo_black/`) | OFL-1.1 | npm `@fontsource/archivo-black` 5.3.0, latin + latin-ext woff2 merged to one TTF with fontTools | Brutalist display face, UPPERCASE headlines only (brutalist-ui.md). Licence text in `OFL.txt` and on the licence page |
| Dena Icons (`app/assets/fonts/dena_icons/`) | GPL-3.0-or-later (ours) | Drawn from primitives by `tools/icons/build_icons.py` (fontTools + skia-pathops, build-time only) | The app's own icon set replacing Material icons |
| SQLite (`libsqlite3.so`, linux-arm64) | Public domain | Prebuilt by the `sqlite3` Dart package's build hook (already used on Android) | Handheld payload `lib/` |
| Debian 12 arm64 sysroot (build time only, not shipped) | libdrm MIT, Mesa gbm MIT, libglvnd MIT-style, Khronos headers MIT-style, alsa-lib LGPL-2.1 | `tools/toolchain/sysroot.py` (pinned sha256) | Headers and link-only libraries; the device's own libraries are used at run time |

## Bundled shaders (`host/shaders/`)

Shipped as app assets (docs/specs/shaders.md). Authors and sources per shader
are in [host/shaders/README.md](../host/shaders/README.md); every source keeps
its licence header.

| Name | License | Source | Notes |
| --- | --- | --- | --- |
| `sharp-bilinear`, `crt-lottes`, `lcd3x`, `dot-matrix` | Public domain | libretro `glsl-shaders` via Cannelloni | |
| `crt-fast`, `lcd-grid`, `crt-geom` | GPL-2.0-or-later | libretro `glsl-shaders` via Cannelloni | distributed under GPL-3.0-or-later |
| `crt-easymode`, `crt-aperture` | GPL (no version given, so any) | libretro `glsl-shaders` via Cannelloni | distributed under GPL-3.0-or-later |
| `crt-bloom` | GPL (derivative of crt-easymode) | Cannelloni `crt-cannelloni` (Denarmo) | distributed under GPL-3.0-or-later |
| `scanlines` | GPL-3.0-or-later | our own | |
| `_upscale` (`xbrz-freescale`) | GPL-3.0 (xBRZ, Zenju); MIT (Hyllian's xBR code) | libretro `glsl-shaders` | upscale filter for GB, GBC, DS |

## Bundled slang shaders (`host/slang-shaders/`, desktop only)

Shipped beside the desktop host library (docs/specs/shader-stacks.md). Copied
unmodified from `libretro/slang-shaders` @
`e1d75632a205c70f14a4cc947c46d5abb7b3f7f1` (2026-10-08), only the files the
presets below need; authors per file are in
[host/slang-shaders/README.md](../host/slang-shaders/README.md) and every
source keeps its header.

| Name | License | Source | Notes |
| --- | --- | --- | --- |
| `sharp-bilinear` (`sharp-bilinear-simple`), `crt-lottes` (`crt-lottes-fast`), `lcd3x`, `dot-matrix` (`dot`) | Public domain | libretro `slang-shaders` | |
| `crt-fast` (`zfast-crt`), `lcd-grid` (`zfast-lcd`), `crt-geom` | GPL-2.0-or-later | libretro `slang-shaders` | distributed under GPL-3.0-or-later; `zfast_crt_finemask.slang` (an include wrapper) has no header and belongs to zfast-crt |
| `crt-easymode`, `crt-aperture` | GPL (no version given, so any) | libretro `slang-shaders` | distributed under GPL-3.0-or-later |
| `crt-royale` (12 passes, 6 mask PNGs) | GPL-2.0-or-later (TroggleMonkey); the blur passes and `include/*.h` MIT (TroggleMonkey) | libretro `slang-shaders` `crt/crt-royale`, `blurs/shaders/royale`, `include` | distributed under GPL-3.0-or-later; `user-settings.h`, `user-cgp-constants.h` and the small `.slang` wrappers have no header and are part of the same package; `include/compat_macros.inc` is a few `#define`s |
| `crt-guest-advanced` (12 passes, 4 LUT PNGs) | GPL-2.0-or-later (guest(r), Dr. Venom) | libretro `slang-shaders` `crt/shaders/guest/advanced` | distributed under GPL-3.0-or-later; its headerless `stock.slang` replaced by our own passthrough |
| `gtu` (`gtu-v050`, 3 passes) | GPL-3.0 ("GPLv3", aliaspider) | libretro `slang-shaders` `crt/shaders/gtu-v050` | `config.h` (headerless, 4 lines) belongs to it |
| `scanlines`, `dena/stock` | GPL-3.0-or-later | our own (`host/slang-shaders/dena/`) | slang port of the phone scanlines |

Not bundled: `ntsc-adaptive` and guest's `-ntsc` presets (their passes carry no
licence statement).

## Dart packages (`app/pubspec.lock`)

The license column is what the package's own LICENSE file says. `sky_engine`
bundles third-party code under several permissive licenses; its LICENSE file
starts with Apache-2.0.

| Name | License | Kind |
| --- | --- | --- |
| `_fe_analyzer_shared` | BSD-3-Clause | Dart package |
| `analyzer` | BSD-3-Clause | Dart package |
| `archive` | MIT | Dart package |
| `args` | BSD-3-Clause | Dart package |
| `async` | BSD-3-Clause | Dart package |
| `boolean_selector` | BSD-3-Clause | Dart package |
| `build` | BSD-3-Clause | Dart package |
| `build_config` | BSD-3-Clause | Dart package |
| `build_daemon` | BSD-3-Clause | Dart package |
| `build_runner` | BSD-3-Clause | Dart package |
| `built_collection` | BSD-3-Clause | Dart package |
| `built_value` | BSD-3-Clause | Dart package |
| `characters` | BSD-3-Clause | Dart package |
| `charcode` | BSD-3-Clause | Dart package |
| `checked_yaml` | BSD-3-Clause | Dart package |
| `cli_util` | BSD-3-Clause | Dart package |
| `clock` | Apache-2.0 | Dart package |
| `code_assets` | BSD-3-Clause | Dart package |
| `collection` | BSD-3-Clause | Dart package |
| `convert` | BSD-3-Clause | Dart package |
| `cross_file` | BSD-3-Clause | Dart package |
| `crypto` | BSD-3-Clause | Dart package |
| `cupertino_ui` | BSD-3-Clause | Dart package |
| `dart_style` | BSD-3-Clause | Dart package |
| `dena_android` | GPL-3.0-or-later | Dart package (ours, `shells/android`) |
| `drift` | MIT | Dart package |
| `drift_dev` | MIT | Dart package |
| `drift_flutter` | MIT | Dart package |
| `dynamic_color` | Apache-2.0 | Dart package |
| `fake_async` | Apache-2.0 | Dart package |
| `ffi` | BSD-3-Clause | Dart package |
| `file` | BSD-3-Clause | Dart package |
| `file_selector_linux` | BSD-3-Clause | Dart package |
| `file_selector_platform_interface` | BSD-3-Clause | Dart package |
| `file_selector_windows` | BSD-3-Clause | Dart package |
| `fixnum` | BSD-3-Clause | Dart package |
| `flutter` | BSD-3-Clause | Dart package |
| `flutter_driver` | BSD-3-Clause | Dart package |
| `flutter_lints` | BSD-3-Clause | Dart package |
| `flutter_localizations` | BSD-3-Clause | Dart package |
| `flutter_test` | BSD-3-Clause | Dart package |
| `fuchsia_remote_debug_protocol` | BSD-3-Clause | Dart package |
| `glob` | BSD-3-Clause | Dart package |
| `graphs` | BSD-3-Clause | Dart package |
| `hooks` | BSD-3-Clause | Dart package |
| `http` | BSD-3-Clause | Dart package |
| `http_multi_server` | BSD-3-Clause | Dart package |
| `http_parser` | BSD-3-Clause | Dart package |
| `integration_test` | BSD-3-Clause | Dart package |
| `intl` | BSD-3-Clause | Dart package |
| `io` | BSD-3-Clause | Dart package |
| `jni` | BSD-3-Clause | Dart package |
| `jni_flutter` | BSD-3-Clause | Dart package |
| `jni_util` | BSD-3-Clause | Dart package |
| `json_annotation` | BSD-3-Clause | Dart package |
| `leak_tracker` | BSD-3-Clause | Dart package |
| `leak_tracker_flutter_testing` | BSD-3-Clause | Dart package |
| `leak_tracker_testing` | BSD-3-Clause | Dart package |
| `lints` | BSD-3-Clause | Dart package |
| `logging` | BSD-3-Clause | Dart package |
| `matcher` | BSD-3-Clause | Dart package |
| `material_color_utilities` | Apache-2.0 | Dart package |
| `material_ui` | BSD-3-Clause | Dart package |
| `meta` | BSD-3-Clause | Dart package |
| `mime` | BSD-3-Clause | Dart package |
| `native_toolchain_c` | BSD-3-Clause | Dart package |
| `objective_c` | BSD-3-Clause | Dart package |
| `package_config` | BSD-3-Clause | Dart package |
| `path` | BSD-3-Clause | Dart package |
| `path_provider` | BSD-3-Clause | Dart package |
| `path_provider_android` | BSD-3-Clause | Dart package |
| `path_provider_foundation` | BSD-3-Clause | Dart package |
| `path_provider_linux` | BSD-3-Clause | Dart package |
| `path_provider_platform_interface` | BSD-3-Clause | Dart package |
| `path_provider_windows` | BSD-3-Clause | Dart package |
| `platform` | BSD-3-Clause | Dart package |
| `plugin_platform_interface` | BSD-3-Clause | Dart package |
| `pool` | BSD-3-Clause | Dart package |
| `posix` | MIT | Dart package |
| `process` | BSD-3-Clause | Dart package |
| `pub_semver` | BSD-3-Clause | Dart package |
| `pubspec_parse` | BSD-3-Clause | Dart package |
| `recase` | BSD-2-Clause | Dart package |
| `record_use` | BSD-3-Clause | Dart package |
| `shelf` | BSD-3-Clause | Dart package |
| `shelf_web_socket` | BSD-3-Clause | Dart package |
| `sky_engine` | Apache-2.0 | Dart package |
| `source_gen` | BSD-3-Clause | Dart package |
| `source_span` | BSD-3-Clause | Dart package |
| `sqlcipher_flutter_libs` | Apache-2.0 | Dart package |
| `sqlite3` | MIT | Dart package |
| `sqlite3_flutter_libs` | MIT | Dart package |
| `sqlparser` | MIT | Dart package |
| `stack_trace` | BSD-3-Clause | Dart package |
| `stream_channel` | BSD-3-Clause | Dart package |
| `stream_transform` | BSD-3-Clause | Dart package |
| `string_scanner` | BSD-3-Clause | Dart package |
| `sync_http` | BSD-3-Clause | Dart package |
| `term_glyph` | BSD-3-Clause | Dart package |
| `test_api` | BSD-3-Clause | Dart package |
| `typed_data` | BSD-3-Clause | Dart package |
| `vector_math` | BSD-3-Clause | Dart package |
| `vm_service` | BSD-3-Clause | Dart package |
| `watcher` | BSD-3-Clause | Dart package |
| `web` | BSD-3-Clause | Dart package |
| `web_socket` | BSD-3-Clause | Dart package |
| `web_socket_channel` | BSD-3-Clause | Dart package |
| `webdriver` | Apache-2.0 | Dart package |
| `xdg_directories` | BSD-3-Clause | Dart package |
| `yaml` | MIT | Dart package |
| `yaml_edit` | BSD-3-Clause | Dart package |

## Native and Gradle dependencies

| Name | License | Used by |
| --- | --- | --- |
| Oboe (`com.google.oboe:oboe`) | Apache-2.0 | `shells/android` audio output |
| AndroidX Media3 (`androidx.media3:media3-exoplayer`, `media3-session` 1.8.0, with Guava) | Apache-2.0 | `shells/android` music and video players (media-players.md) |
| Zig 0.17.0 (build tool, not shipped) | MIT. C++ cores link its libc++/libc++abi/libunwind statically (Apache-2.0 WITH LLVM-exception, GPL-3.0 compatible); glibc stubs only stand in for the device's own glibc at link time | aarch64 Linux cross builds (`tools/toolchain`, toolchain-linux.md) |
| Microsoft Visual C++ runtime (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`, from Visual Studio 2022's `VC\Redist\MSVC`) | Proprietary: Visual Studio "Distributable Code" (`redist.txt`), free to ship app-local, not open source. GPL system-library exception applies (part of the compiler's runtime) | Windows release packages (release-windows.md), for the MSVC-built Flutter runner and plugins |
| Inno Setup 6.3+ (build tool; its setup stub ships inside the installer) | Inno Setup License (modified BSD-style, commercial use allowed) | `tools/release/windows/dena-emu.iss`, the Windows installer (release-windows.md) |
| chdman (MAME, external tool, not bundled) | GPL-2.0-or-later (MAME's BSD-3-Clause/GPL-2.0+ mix) | Desktop disc conversion to CHD (rom-manager.md 3); run as a separate process found by `ToolLocator`, never linked |
| DolphinTool (Dolphin, external tool, not bundled) | GPL-2.0-or-later | Desktop disc conversion to RVZ (rom-manager.md 3); run as a separate process, never linked |

## Single-card image (`os/image`)

Built from source by `os/image/build.sh` (docs/specs/single-card.md), never
committed. Everything here ships on the card, so a public image must come
with the corresponding source (single-card.md, Not yet).

| Name | License | Source | Pinned |
| --- | --- | --- | --- |
| Linux | GPL-2.0-only | https://github.com/gregkh/linux (stable) | tag `v7.1.2`, `03e2778d1f11de9260543f969e9e888a1c2bf830` |
| H700 kernel patches (`os/image/linux/patches`) | GPL-2.0-only (kernel patches, each by its upstream author) | ROCKNIX public H700 patch set | in git |
| RTL8821C Wi-Fi firmware (`rtw88/rtw8821c_fw.bin`, built into the kernel) | Realtek redistributable binary licence (`os/image/linux/firmware-licences/LICENCE.rtlwifi_firmware.txt`, shipped in `/usr/share/licenses/firmware`) | https://gitlab.com/kernel-firmware/linux-firmware | tag `20260916`, sha256 in `os/image/linux/firmware.txt` |
| U-Boot | GPL-2.0-or-later | https://github.com/u-boot/u-boot | tag `v2026.01`, `127a42c7257a6ffbbd1575ed1cbaa8f5408a44b3` |
| Trusted Firmware-A (BL31) | BSD-3-Clause | https://github.com/ARM-software/arm-trusted-firmware | tag `v2.15.0`, `da738d5eae93af342fdc4995dd3c05acb4c9d757` |
| Debian 13 arm64 base (`os/image/rootfs/packages.txt`) | busybox GPL-2.0; glibc LGPL-2.1+; libstdc++/libgcc GPL-3.0 with the GCC runtime exception; Mesa MIT, its LLVM Apache-2.0 WITH LLVM-exception; libdrm MIT; libglvnd MIT-style; alsa-lib LGPL-2.1+; systemd's libudev LGPL-2.1+; util-linux (sfdisk, addpart) GPL-2.0+, its libraries LGPL/BSD; exfatprogs GPL-2.0; wpa_supplicant BSD-3-Clause; wireless-regdb ISC; and their dependencies under their Debian copyright files | deb.debian.org | Debian trixie at build time |

## Emulator cores

Built from source by `cores/<core>/build.sh`, never committed. Planned cores
and their licenses are in CLAUDE.md §3. Desktop (win64, linux-x86_64) builds of
the same cores use the same pinned commits (docs/dev/desktop-cores.md).

| Core | License | Upstream | Pinned |
| --- | --- | --- | --- |
| mGBA (GB/GBC/GBA) | MPL-2.0 | https://github.com/mgba-emu/mgba | tag `0.10.5`, `26b7884bc25a5933960f3cdcd98bac1ae14d42e2` |
| FCEUmm (NES) | GPL-2.0-or-later | https://github.com/libretro/libretro-fceumm | `ac0d00a7fc01166f84c7bac01d1084ebfd2b865e` |
| bsnes (SNES) | GPL-3.0-only | https://github.com/libretro/bsnes | `63ee22f7af8f5d1ada295c2c98fd7bf261fa62a7` |
| PCSX ReARMed (PlayStation) | GPL-2.0-or-later; bundled lightrec LGPL-2.1, GNU lightning LGPL-3.0, libchdr BSD-3-Clause, zlib Zlib | https://github.com/libretro/pcsx_rearmed | `c8816799b50388e61cfe237fe2cdbb7d8175f20a` |
| Mupen64Plus-Next (N64) | GPL-2.0-or-later; bundled GLideN64 GPL-2.0, RSP HLE GPL-2.0, RSP cxd4 CC0-1.0, xxHash BSD-2-Clause, libretro-common MIT. The Android build leaves out paraLLEl and angrylion. | https://github.com/libretro/mupen64plus-libretro-nx | `12edd2c74a517ff86dfa8cfc71ad75e4c10486d5` |
| PPSSPP (PSP) | GPL-2.0-or-later; bundled prebuilt FFmpeg (LGPL-2.1-or-later build, hrydgard/ppsspp-ffmpeg at the pinned submodule), glslang BSD-3-Clause/Apache-2.0, SPIRV-Cross Apache-2.0, zstd BSD-3-Clause, cpu_features Apache-2.0, rcheevos MIT, naett MIT, libchdr BSD-3-Clause, libadrenotools BSD-2-Clause, Lua MIT, armips MIT, RapidJSON MIT, OpenXR headers Apache-2.0. Packaged assets (`assets/flash0` fonts, VFPU tables, PPGe atlas, compat.ini, English strings) come from the same repository under its license. | https://github.com/hrydgard/ppsspp | tag `v1.19.3`, `e49c0bd8836a8a8f678565357773386f1174d3f5` |
| fake-08 (PICO-8 compatible runtime) | MIT; bundled z8lua (Lua 5.2 fork) MIT, zepto8-derived code WTFPL-2, tac08 font table MIT (the PICO-8 font itself is CC0 from Lexaloffle), PicoLove zlib, LodePNG zlib-style, miniz MIT, simpleini MIT. Its `oval()`/`ovalfill()` (from a CC BY-SA 3.0 snippet) are removed at build time and replaced with our own (`cores/fake08/dena_oval.inc`). | https://github.com/jtothebell/fake-08 | `814991a2571ad3970e386cef48f3b148aa1c27b9` |
| melonDS (DS) | GPL-3.0-or-later; bundled FreeBIOS (Gilead Kutnick) BSD-2-Clause | https://github.com/libretro/melonDS | `66b5d2634cd0a79030562811e6e05f5532f800ba` + our `cores/melonds/patches/gles3.patch` (GPL-3.0-or-later) |
| Beetle PSX HW (PlayStation, desktop) | GPL-2.0-or-later (Mednafen); bundled Lightrec LGPL-2.1-or-later, GNU lightning LGPL-3.0-or-later, PCSX-Redux OpenBIOS MIT, parallel-psx ISC, SPIRV-Cross Apache-2.0, Khronos headers MIT-style, libretro-common MIT | https://github.com/libretro/beetle-psx-libretro | `6454af0a690a5e004211bce8e62286bd18acd87d` |
| Flycast (Dreamcast, NAOMI, Atomiswave; desktop) | GPL-2.0-or-later; bundled xBRZ GPL-3.0 (so the built core is GPL-3.0), picoTCP GPL-2.0-or-later, libchdr BSD-3-Clause, glslang BSD-3-Clause/Apache-2.0, Vulkan-Headers Apache-2.0, VulkanMemoryAllocator MIT, rcheevos MIT, asio BSL-1.0, nowide BSL-1.0, xbyak BSD-3-Clause, tinygettext zlib, libzip BSD-3-Clause, LZMA SDK public domain, xxHash BSD-2-Clause, libelf BSD-2-Clause, glm MIT, stb MIT/public domain, nlohmann json MIT, imgui MIT, md5 public domain (Solar Designer), SDL zlib. Built without OpenMP, Lua, breakpad and Discord. | https://github.com/flyinghead/flycast | tag `v2.7`, `5aa091fde632fb332c8d8c34e280d62dc951954c` |
| Beetle Saturn (Saturn, desktop) | GPL-2.0-or-later (Mednafen); bundled Tremor BSD-3-Clause, libretro-common MIT | https://github.com/libretro/beetle-saturn-libretro | `faef2779a7568c1734addc4fe63cc76e9fa2566b` |
| Dolphin libretro fork (GameCube, Wii; desktop) | GPL-2.0-or-later; bundled Bochs disassembler LGPL-2.1-or-later, bzip2 bzip2-1.0.6, cpp-ipc MIT, cwdemangle CC0-1.0, ENet MIT, expr MIT, FatFs BSD-1-Clause, FreeSurround GPL-2.0-or-later, fmt MIT, glslang BSD-3-Clause/Apache-2.0, SPIRV-Cross Apache-2.0, VulkanMemoryAllocator MIT, Vulkan-Headers Apache-2.0, imgui MIT, implot MIT, libiconv LGPL-2.1-or-later, LZO GPL-2.0-or-later, lz4 BSD-2-Clause, liblzma public domain, libspng BSD-2-Clause, libusb LGPL-2.1-or-later, mGBA MPL-2.0, mbedTLS Apache-2.0, minizip-ng zlib, MiniUPnPc BSD-3-Clause, hidapi BSD-3-Clause, ed25519 zlib, curl curl licence (MIT-style), tinygltf MIT, cpp-optparse MIT, watcher MIT, picojson BSD-2-Clause, pugixml MIT, SFML zlib, wil MIT, xxHash BSD-2-Clause, zlib-ng zlib, zstd BSD-3-Clause, libretro-common MIT. Built with `-DLIBRETRO=ON` (no Qt, SDL, cubeb, ALSA or RetroAchievements code). Its `Data/Sys` folder (GameCube fonts, game INI files, shaders) ships beside the core under the same licence. | https://github.com/libretro/dolphin | `5466da350f2fd143ee3e7b921e8c33aee64f7065` |
| LRPS2 (PlayStation 2, desktop; PCSX2 libretro fork) | GPL-3.0-or-later (PCSX2); bundled paraLLEl-GS LGPL-3.0-or-later, Granite MIT, volk MIT, glad MIT, glslang BSD-3-Clause/Apache-2.0, Vulkan-Headers Apache-2.0, xbyak BSD-3-Clause, VIXL BSD-3-Clause (arm64 builds only), libretro-common MIT. Built without pcap. Needs the player's own PS2 BIOS; none is shipped | https://github.com/libretro/ps2 | `d4908f40fb32f43c5055852ecaed3c52aa725dce` |

## Data

| Data | License | Source | Notes |
| --- | --- | --- | --- |
| Box-art lookup index (`app/assets/boxart/index.tsv.gz`) | CC-BY-SA-4.0 | libretro-database `metadat/no-intro` and `metadat/redump` (PS1, PSP), commit `12c21cf79f1e20eff6ac68b80875816c717d0a7a` | Generated by `tools/boxart/build_index.py`; credited in the app's licence page |
| Cheat file index (`app/assets/cheats/index.tsv.gz`) | CC-BY-SA-4.0 | libretro-database `cht/`, commit `12c21cf79f1e20eff6ac68b80875816c717d0a7a` | File names only, generated by `tools/cheats/build_index.py`; credited in the app's licence page and the cheat browser |
| Cheat files (`.cht`) | CC-BY-SA-4.0, not bundled | libretro-database `cht/` at the same commit | Downloaded on demand per game (cheats.md) |
| Cover images | Not bundled | libretro thumbnail server | Fetched on demand per user (box-art.md) |
| No-Intro and Redump DATs (`<system>.dat`) | CC-BY-SA-4.0 (libretro-database), not bundled | libretro-database `metadat/no-intro` and `metadat/redump`, commit `12c21cf79f1e20eff6ac68b80875816c717d0a7a` (UPDATE takes `master`) | Downloaded on demand into `<dataDir>/romtools/dats/` for the hash check (rom-manager.md 1); users can import their own DAT |
| OpenVGDB game database (`openvgdb.sqlite`) | MIT, not bundled | https://github.com/OpenVGDB/OpenVGDB release `v29.0` (`openvgdb.zip`) | Downloaded on demand into `<dataDir>/romtools/` (rom-manager.md 4); its cover URLs point to third-party images fetched only when the user scrapes |
| Console-style skins (`app/assets/skins/*.deltaskin`) | GPL-3.0-or-later | Our own artwork, generated by `tools/skins/build_skins.py` | Built with Pillow (HPND) and NumPy (BSD-3-Clause), build-time only, not shipped; button labels rasterised from DejaVu Sans Bold (Bitstream Vera license, permits embedding). No logos or trademarks (skins.md 8c) |

## Test content

| File | License | Source |
| --- | --- | --- |
| `host/tests/roms/latency/latency.gba` | GPL-3.0-or-later | Our own, generated by `make_rom.py` next to it |
| `app/test/carts/fixtures/listing.html` | GPL-3.0-or-later | Our own invented BBS-style listing (no real BBS content) |
