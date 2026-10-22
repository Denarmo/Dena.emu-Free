# Desktop cores (Windows and SteamOS)

How the libretro cores for the Windows and SteamOS versions are built. Plan:
the desktop port plan, section 2. Per the project rules these builds run on
DENA-PC in WSL2 Debian during the combined desktop test pass, never in the
cloud; cloud threads only check the scripts (`--dry-run`, shellcheck) and may
smoke-build one small core.

## Targets

| Target | Output | Toolchain |
| --- | --- | --- |
| `win64` | `cores/build/win64/<core>_libretro.dll` | MinGW-w64 cross compiler, posix threads (`x86_64-w64-mingw32-gcc-posix`), runtime linked statically |
| `linux-x86_64` | `cores/build/linux-x86_64/<core>_libretro.so` | gcc inside the freedesktop Flatpak SDK (`cores/desktop-runtime.txt`, now 26.08) |

Linux cores are built inside the same SDK the SteamOS Flatpak runs on, so they
link against that runtime's glibc and libraries and run on SteamOS and any
other distro with the Flatpak. The Flatpak manifest must use the `runtime=`
line of `cores/desktop-runtime.txt`.

## Cores per target

| System | Core (script) | win64 | linux-x86_64 | Notes |
| --- | --- | --- | --- | --- |
| NES | FCEUmm (`fceumm`) | yes | yes | |
| SNES | bsnes (`bsnes`) | yes | yes | |
| GB/GBC/GBA | mGBA (`mgba`) | yes | yes | link cable hooks as on Android |
| PICO-8 | fake-08 (`fake08`) | yes | yes | same fixups as on Android |
| PlayStation | Beetle PSX HW (`beetle_psx`) | yes | yes | `HAVE_HW=1`: OpenGL + Vulkan, Lightrec x86_64 dynarec. PCSX ReARMed stays ARM only and refuses desktop targets |
| Saturn | Beetle Saturn (`beetle_saturn`) | yes | yes | new core, software renderer; app system since dreamcast-saturn.md |
| DS | melonDS (`melonds`) | yes | yes | x86_64 JIT, desktop OpenGL renderer |
| N64 | Mupen64Plus-Next (`mupen64plus`) | yes | yes | x86_64 dynarec (needs `nasm`), GLideN64 on desktop OpenGL |
| Dreamcast | Flycast (`flycast`) | yes | yes | new core, x86_64 dynarec, OpenGL + Vulkan; app system since dreamcast-saturn.md |
| GameCube/Wii | Dolphin (`dolphin`) | yes, **MSVC** (`build-msvc.ps1`) | yes | libretro fork, x86_64 JIT, OpenGL + Vulkan, every library bundled; ships `dolphin-emu/Sys` beside the core; app systems since gamecube-wii.md |
| PSP | PPSSPP (`ppsspp`) | yes, no FFmpeg | yes | x86_64 JIT. win64 builds without FFmpeg: PPSSPP's prebuilt FFmpeg does not link with MinGW, so PSP video cutscenes stay black on Windows until that is solved |
| PS2 | LRPS2 (`lrps2`) | MSVC only | yes | PCSX2 libretro fork, x86_64 recompilers, OpenGL + Vulkan; app system since ps2.md. libretro builds it for Windows with MSVC only, so `build-desktop.sh win64` skips it and `cores\lrps2\build-msvc.ps1` builds `pcsx2_libretro.dll` on Windows (see below). Needs the player's own BIOS |

Not here: 3DS (waits for the owner's legal
sign-off). Every core's licence row is in `docs/licenses.md`; all builds use
the same pinned commits as the other targets.

## Setup on DENA-PC (WSL2 Debian, once)

```sh
sudo apt install build-essential cmake nasm ccache git mingw-w64 flatpak
sudo update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
sudo update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.freedesktop.Sdk/x86_64/26.08
```

The scripts pick the `-posix` compilers by name, so the alternatives step is
only for builds outside these scripts. The SDK brings its own gcc, cmake,
nasm, git and ccache.

Build from the Linux file system (for example `~/src/Dena.emu`, a worktree
per thread), not from `/mnt/c`: builds on the Windows drive are many times
slower.

## Building

```sh
cores/build-desktop.sh win64                  # all cores, MinGW cross build
cores/build-desktop.sh linux-x86_64           # all cores, inside the Flatpak SDK
cores/build-desktop.sh linux-x86_64 --native  # host gcc, quick checks only
cores/build-desktop.sh win64 flycast melonds  # just these cores
cores/build-desktop.sh --dry-run win64        # print every command, change nothing
cores/flycast/build.sh --target win64         # one core directly
```

`build-desktop.sh` builds every core even when one fails and lists the
failures at the end. Every core compiles with `nproc` jobs; set `DENA_JOBS` to
use fewer. PPSSPP needs about 1 GB per job, so on DENA-PC's WSL (15 GB) use
`DENA_JOBS=8`, and never build both targets at once. Each per-core script also takes `--dry-run` and
`--target <t>` (or the target as the first argument, like the other targets).

## Dolphin on Windows (MSVC)

Dolphin's Windows DLL is the one core built with MSVC on Windows itself,
not cross-built in WSL: `cores/build-desktop.sh win64` skips it and says so.
On DENA-PC, once:

1. Visual Studio 2022 (Community or Build Tools) with the "Desktop
   development with C++" workload, which brings MSVC v143, a Windows 10/11
   SDK and CMake. The Flutter Windows build already needs this. The pinned
   Dolphin commit asks for Visual Studio 2026 (MSVC 19.51) in its
   precompiled header; `patches/0001-pch-allow-vs2022.patch` lowers that
   check to VS 2022 17.14 (MSVC 19.44), which builds it cleanly (desktop
   pass 3, 2026-10-18).
2. Git for Windows on the PATH, with long paths: `git config --global
   core.longpaths true` (the script also sets it in the Dolphin checkout).

Then, from a Windows checkout in PowerShell (not the WSL one; the source and
objects go to `cores\build\src\dolphin` and `cores\build\obj\dolphin-msvc`):

```powershell
cores\dolphin\build-msvc.ps1                      # -> cores\build\win64
cores\dolphin\build-msvc.ps1 -OutDir \\wsl.localhost\Debian\home\david\src\Dena.emu\cores\build\win64
cores\dolphin\build-msvc.ps1 -DryRun              # print the commands
```

It fetches the pinned commit and its submodules (not Qt, prebuilt FFmpeg,
gtest or Android drivers), applies `cores/dolphin/patches`, configures
with the "Visual Studio 17 2022" generator (`-A x64`, Release,
`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`, so the DLL needs no Visual C++
redistributable), builds the `dolphin_libretro` target and writes
`dolphin_libretro.dll` plus `dolphin-emu\Sys` (stamped `dena-assets.txt`).
With `dumpbin` on the PATH (a Developer PowerShell) it fails when the DLL
still imports `msvcp140`/`vcruntime140`. A first build takes a while (about
1,300 objects); `-Jobs` limits the parallel compiles.

`tools\release\build-windows.ps1 -WslRepo ...` runs it after the WSL cores,
writing into the WSL cores folder, so one release command still builds
everything; `-SkipDolphin` leaves it out (an existing DLL still ships).

## Dolphin on Linux

`cores/dolphin/build.sh linux-x86_64` uses Ninja and needs CMake 3.25 or
newer. The 26.08 SDK has one; the portable 22.08 SDK (tar.gz,
release-linux.md) is older, so the script then downloads the pinned Kitware
CMake 3.31.6 (checked by SHA-256) into `cores/build/tools`. Every library is
bundled (`USE_SYSTEM_LIBS=OFF`) and X11, audio and controller backends are
off (the frontend owns them), so the `.so` needs only libc, libstdc++ and
GL from the runtime. GCC 12 in the 22.08 SDK is the oldest compiler it has
to build with.
## LRPS2 on Windows (MSVC)

The PS2 core is the one desktop core built natively on Windows, not in WSL:

```powershell
powershell -ExecutionPolicy Bypass -File cores\lrps2\build-msvc.ps1            # -> cores\build\win64
powershell -File cores\lrps2\build-msvc.ps1 -OutDir <dir> -Jobs 8
powershell -File cores\lrps2\build-msvc.ps1 -DryRun                            # print the steps
```

It needs Git and Visual Studio 2022 with "Desktop development with C++" (the
same install the Flutter runner needs), fetches the commit pinned in
`cores/lrps2/build.sh` into `cores\build\src\lrps2-msvc` and builds it with
the Visual Studio generator. `tools\release\build-windows.ps1 -WslRepo ...`
runs it after the WSL cores and puts the DLL next to them; if it fails the
release ships without PS2 and says so in the notes. The DLL links the Visual
C++ runtime the package already ships app-local.

## ccache

Every desktop compile goes through `ccache` when it is installed (set
`DENA_CCACHE=0` to turn it off). The cache is `$CCACHE_DIR` or
`~/.cache/ccache`; the Flatpak build mounts the same directory into the SDK, so
both targets and repeated passes share it. A good size for all twelve cores and
both targets: `ccache -M 20G`. Objects stay under `cores/build/obj/<core>-<target>`
(a copy of the tracked sources per target), so unchanged cores also skip make's
work entirely.

## Checks the scripts do

- The checkout is the pinned commit (or tag) from `docs/licenses.md`.
- After the build the library is stripped. A win64 DLL that still imports the
  MinGW runtime (`libgcc_s`, `libstdc++`, `libwinpthread`, `libgomp`) fails the
  build: the Windows app ships each core as one DLL. Linux builds print the
  `.so`'s `NEEDED` libraries, which should all be in the freedesktop runtime.

## Files

- `cores/desktop.sh`: shared helpers (target parsing, dry run, toolchains,
  ccache, library check), sourced by the core scripts.
- `cores/libretro-make.sh`: Makefile cores; desktop variables `X64_MAKE`,
  `WIN64_MAKE`, `LINUX64_MAKE`, `DESKTOP_SKIP`.
- `tools/toolchain/x86_64-w64-mingw32.cmake`: CMake toolchain for the CMake
  cores (mGBA, Flycast, PPSSPP).
- `cores/desktop-runtime.txt`: the Flatpak SDK and runtime.
- `tools/toolchain/test_desktop_cores.py`: dry-run test for every core and
  target (runs with `tools/ci/local.sh rig`).
