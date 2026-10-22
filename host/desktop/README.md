# host/desktop

The desktop host library: `dena_host.dll` (Windows x86_64) and
`libdena_host.so` (Linux x86_64, SteamOS). The shared runner with an SDL3
platform, loaded at run time by the Flutter runners in `app/windows` and
`app/linux`. Spec: [docs/specs/desktop-shell.md](../../docs/specs/desktop-shell.md).

## Build (WSL2 Debian on DENA-PC)

Packages once:

    sudo apt install cmake ninja-build g++ mingw-w64 libegl-dev libgl-dev \
      libasound2-dev libpulse-dev libpipewire-0.3-dev libudev-dev

Linux (from the repo root; the Flatpak build will use the freedesktop SDK
instead):

    cmake -S host/desktop -B build/desktop-linux -G Ninja -DCMAKE_BUILD_TYPE=Release
    ninja -C build/desktop-linux && ctest --test-dir build/desktop-linux

Windows, cross-built with MinGW-w64 (no MSVC needed for the library):

    cmake -S host/desktop -B build/desktop-win64 -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE="$PWD/host/desktop/cmake/mingw-w64-x86_64.cmake"
    ninja -C build/desktop-win64

The tests in `build/desktop-win64` are Windows programs: run
`desktop_map_tests.exe` and
`desktop_host_tests.exe dena_host.dll <full path of testcore_libretro.dll> <empty dir>` from
a Windows shell.

SDL3 3.2.24 is downloaded and built static on the first configure (pinned by
SHA-256). Offline, pass `-DDENA_SDL3_URL=file:///path/SDL3-3.2.24.tar.gz`, or
`-DDENA_SYSTEM_SDL3=ON` for an installed SDL3. On Linux check the configure
summary lists `SDL_PIPEWIRE`, `SDL_PULSEAUDIO` or `SDL_ALSA` as ON, or games
are silent.

Then the app (on Windows, Visual Studio 2022 with "Desktop development with
C++"): `flutter build windows` / `flutter build linux` in `app/` copy the
library from `build/desktop-*` and the cores from `cores/build/win64` /
`cores/build/linux-x86_64` into the bundle.

## Licences

SDL3 is zlib-licensed (commercial use allowed); its row is in
`docs/licenses.md` and it is on the app's licence page in desktop builds.
rcheevos (MIT) as in the other shells.
