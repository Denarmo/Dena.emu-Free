# Windows release

How DENA-PC builds the two Windows downloads of a release: a portable zip and
an installer. The plan is in the desktop port plan (packaging section); the
app side is [docs/specs/desktop-shell.md](../specs/desktop-shell.md).

| File | What it is |
| --- | --- |
| `dena-emu-X.Y.Z-windows-x64-portable.zip` | One `Dena.emu` folder: the app, `dena_host.dll`, `cores\`, licences and `portable.txt`, so all data lives in `Dena\` beside the exe |
| `dena-emu-X.Y.Z-windows-x64-setup.exe` | Inno Setup installer: per user (no admin) into `%LOCALAPPDATA%\Programs\Dena.emu`, Start menu entry, optional desktop shortcut, optional "Open with" entries (off by default; opening a game starts it, [open-with.md](../specs/open-with.md)), uninstaller. Data stays in `%APPDATA%\Dena.emu` |

`X.Y.Z` is the `version:` line of `app/pubspec.yaml` without the `+build`
number.

## One-time setup on DENA-PC

1. Visual Studio 2022 with "Desktop development with C++" (the Flutter runner,
   and the Visual C++ runtime DLLs the package ships app-local).
2. Flutter stable on the PATH (`flutter doctor` shows Windows OK).
3. Inno Setup **6.3 or newer** (needed for `x64compatible`):
   `winget install JRSoftware.InnoSetup`, or the installer from
   <https://jrsoftware.org/isdl.php>. The script finds `ISCC.exe` on the PATH,
   in `Program Files (x86)\Inno Setup 6` or in
   `%LOCALAPPDATA%\Programs\Inno Setup 6`; otherwise pass `-Iscc <path>`.
4. WSL2 Debian with the packages from [desktop-cores.md](desktop-cores.md) and
   [host/desktop/README.md](../../host/desktop/README.md) (MinGW-w64, cmake,
   ninja, nasm, ccache), and a checkout on the Linux file system (for example
   `~/src/Dena.emu-<branch>`, a worktree) at the same commit as the Windows
   checkout. Builds from `/mnt/c` are many times slower.

## Building

From the Windows checkout (its own worktree, main checkout stays on `main`):

```powershell
# Everything: dena_host.dll and the cores in WSL, LRPS2 (PS2) and Dolphin
# (GameCube, Wii) with MSVC, then Flutter, zip, installer.
tools\release\build-windows.ps1 -WslRepo /home/david/src/Dena.emu-desktop-pass

# The DLLs are already built (in this checkout, or anywhere):
tools\release\build-windows.ps1 -HostDir <dir with dena_host.dll> -CoresDir <dir with *_libretro.dll>

# Build flags the app reads (never commit their values):
tools\release\build-windows.ps1 -WslRepo ... -DartDefine DENA_SCREENSCRAPER_DEVID=...,DENA_SCREENSCRAPER_DEVPASSWORD=...

# Layout check without building anything (also runs on Linux with pwsh):
tools\release\build-windows.ps1 -DryRun
```

If PowerShell refuses to run scripts, start it with
`powershell -ExecutionPolicy Bypass -File tools\release\build-windows.ps1 ...`.

Other switches: `-OutDir` (default `build\release`), `-SkipFlutter` (reuse
`app\build\windows\x64\runner\Release`), `-SkipInstaller` (zip only),
`-RequireAllCores` (fail instead of shipping without a core), `-WslDistro`
(default `Debian`).

Output in `build\release\`: both files, `release-notes-windows.md` (printed at
the end, with SHA-256 sums), `stage\Dena.emu` (the installer's files) and
`portable\Dena.emu` (the zip's folder).

## What goes in the package

- The Flutter release bundle (`dena_emu.exe`, `flutter_windows.dll`, plugin
  DLLs, `data\`), without its own `cores\` folder.
- `dena_host.dll` from `-HostDir` (default `build\desktop-win64`). Required.
- `cores\*_libretro.dll` from `-CoresDir` (default `cores\build\win64`): only
  the cores of `cores/build-desktop.sh` plus `pcsx2_libretro.dll` (PS2),
  which `cores\lrps2\build-msvc.ps1` builds with MSVC in this checkout and
  copies there, and Dolphin (`dolphin_libretro.dll`, MSVC, with its
  `cores\dolphin-emu\Sys` folder; `-SkipDolphin` skips its build,
  desktop-cores.md "Dolphin on Windows (MSVC)").
- `msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll` from Visual Studio's
  redist folder (found with `vswhere`), so a fresh Windows needs no VC++
  redistributable. Microsoft allows this app-local copy for the redistributable
  files listed in Visual Studio's `redist.txt`.
- `LICENSE.txt` (GPL-3.0), `licenses\THIRD-PARTY-LICENSES.md` (a copy of
  [docs/licenses.md](../licenses.md)) and `SOURCE.txt` with the source link for
  the exact commit, which covers the GPL source offer for the app and the
  cores.
- Zip only: `portable.txt` and empty `Dena\Roms\<system>` and `Dena\Bios`
  folders.

## When a core does not cross-build

The MinGW cross build makes every Windows core except Dolphin (MSVC). When a core fails
(`cores/build-desktop.sh` names it at the end; PPSSPP, Flycast and Mupen64Plus
are the likely ones), the release ships without it: the script warns, leaves
it out of `cores\` and lists the system under "Not in this build" in the
release notes. That system's games then fail to start with the runner's
"core not found" message; nothing else changes. Pass `-RequireAllCores` to
stop instead. The fix belongs in a follow-up thread on that core's
`cores/<core>/build.sh` (or an MSVC build of that one core); the package script
needs no change, since it copies whatever DLLs exist.

## Steam and controllers

The release notes stub already says this; keep it when editing the draft:

- Add a Non-Steam Game > `dena_emu.exe`; no launch options needed.
- Controller layout "Gamepad", not "Keyboard and Mouse", so Steam Input passes
  the pad through. Disable Steam Input for the shortcut for gyro straight from
  SDL.
- A pad connected at launch opens fullscreen in controller mode; F11 or
  Alt+Enter toggles it.

## Publishing

Draft the GitHub release with both files and the notes (merged with the
Android and Linux notes of the same version); the owner clicks Publish. The
files are not code-signed yet, so SmartScreen warns on first start (the notes
say so).

## Files

- `tools/release/build-windows.ps1`: the entry point above.
- `tools/release/windows/dena-emu.iss`: the installer script. Keep its `AppId`
  unchanged forever: upgrades and the uninstaller find the install by it.
- `tools/release/test_build_windows.py`: runs the dry run with `pwsh` (skipped
  without it) and checks the zip layout and the installer script's settings
  (`tools/ci/local.sh rig`).
