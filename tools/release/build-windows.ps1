# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
Builds the Windows release of Dena.emu: a portable zip and an Inno Setup
installer (docs/dev/release-windows.md).

.DESCRIPTION
Runs on DENA-PC from a Windows checkout (PowerShell 5.1 or 7):
  1. Optionally builds dena_host.dll and the win64 cores in WSL (-WslRepo),
     and the PS2 core (LRPS2) with MSVC here (cores\lrps2\build-msvc.ps1).
  2. flutter build windows --release in app/.
  3. Stages the bundle with dena_host.dll, the cores, the Visual C++ runtime
     and the licences in <OutDir>\stage\Dena.emu.
  4. Writes dena-emu-X.Y.Z-windows-x64-portable.zip (the stage plus
     portable.txt and an empty Dena\ folder) and, with ISCC.exe,
     dena-emu-X.Y.Z-windows-x64-setup.exe.
  5. Writes and prints release-notes-windows.md with the cores that are
     missing, the Steam and controller notes and the SHA-256 of both files.
X.Y.Z is the version line of app/pubspec.yaml without the build number.

Cores that failed to cross-build are left out and listed in the notes; the
release still goes out unless -RequireAllCores is given. dena_host.dll is
required.

-DryRun builds nothing: it stages placeholder files for the Flutter bundle,
dena_host.dll, the cores and the runtime (unless -HostDir / -CoresDir point
at real ones), writes the zip and the notes, and prints the ISCC command
instead of running it. It runs on Linux too (pwsh), which is how the layout
is checked without Windows.

.EXAMPLE
tools\release\build-windows.ps1 -WslRepo /home/david/src/Dena.emu-desktop-pass

.EXAMPLE
tools\release\build-windows.ps1 -DryRun
#>
[CmdletBinding()]
param(
  # Build nothing; stage placeholders and print the commands.
  [switch]$DryRun,
  # Absolute Linux path of a checkout in WSL at the same commit. When given,
  # dena_host.dll and the win64 cores are built there first and taken from it.
  [string]$WslRepo,
  [string]$WslDistro = 'Debian',
  # Folder with dena_host.dll (default: build\desktop-win64 of -WslRepo or of
  # this checkout).
  [string]$HostDir,
  # Folder with the win64 *_libretro.dll cores (default: cores\build\win64 of
  # -WslRepo or of this checkout).
  [string]$CoresDir,
  # Where the artifacts go (default: build\release in this checkout).
  [string]$OutDir,
  # Passed to flutter build as --dart-define=<value> (KEY=value).
  [string[]]$DartDefine = @(),
  # ISCC.exe (default: PATH, then the usual Inno Setup 6 folders).
  [string]$Iscc,
  # Reuse app\build\windows\x64\runner\Release from an earlier build.
  [switch]$SkipFlutter,
  # Write only the portable zip.
  [switch]$SkipInstaller,
  # Fail instead of shipping without the cores that are missing.
  [switch]$RequireAllCores,
  # With -WslRepo: do not build the MSVC Dolphin core (GameCube, Wii); an
  # existing dolphin_libretro.dll in the cores folder still ships.
  [switch]$SkipDolphin
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$IssFile = Join-Path $PSScriptRoot 'windows\dena-emu.iss'

# The win64 cores of cores/build-desktop.sh (docs/dev/desktop-cores.md).
$Cores = [ordered]@{
  'fceumm_libretro.dll'           = 'NES (FCEUmm)'
  'bsnes_libretro.dll'            = 'SNES (bsnes)'
  'mgba_libretro.dll'             = 'GB / GBC / GBA (mGBA)'
  'fake08_libretro.dll'           = 'PICO-8 (fake-08)'
  'mednafen_psx_hw_libretro.dll'  = 'PlayStation (Beetle PSX HW)'
  'mednafen_saturn_libretro.dll'  = 'Saturn (Beetle Saturn)'
  'melonds_libretro.dll'          = 'DS (melonDS)'
  'mupen64plus_libretro.dll'      = 'N64 (Mupen64Plus-Next)'
  'flycast_libretro.dll'          = 'Dreamcast (Flycast)'
  'ppsspp_libretro.dll'           = 'PSP (PPSSPP)'
  'dolphin_libretro.dll'          = 'GameCube / Wii (Dolphin)'
  'pcsx2_libretro.dll'            = 'PS2 (LRPS2, MSVC)'
}

# The Visual C++ runtime the MSVC-built runner and plugins link against,
# shipped app-local so a fresh Windows needs no redistributable installer.
$VcRuntime = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')

# Portable Dena\Roms folders (docs/specs/sd-card.md, the app's system ids).
$RomFolders = @('nes', 'snes', 'gb', 'gbc', 'gba', 'nds', 'n64', 'psx', 'psp', 'pico8',
  'gamecube', 'wii', 'saturn', 'dreamcast', 'ps2')

function Write-Step([string]$Text) { Write-Host "=== $Text" -ForegroundColor Cyan }

function Invoke-Checked {
  param([string]$Exe, [string[]]$Arguments)
  Write-Host "> $Exe $($Arguments -join ' ')"
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

function Get-AppVersion {
  $pubspec = Join-Path $Root 'app\pubspec.yaml'
  foreach ($line in Get-Content -LiteralPath $pubspec) {
    if ($line -match '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
  }
  throw "no version line in $pubspec"
}

function Get-Commit {
  $commit = $null
  if (Get-Command git -ErrorAction SilentlyContinue) {
    $commit = (& git -C $Root rev-parse HEAD 2>$null)
  }
  if (-not $commit) { $commit = 'unknown' }
  return "$commit".Trim()
}

function New-CleanDir([string]$Path) {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function New-Placeholder([string]$Path) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
  Set-Content -LiteralPath $Path -Value "placeholder for $(Split-Path -Leaf $Path) (dry run)"
}

# The WSL checkout as a Windows path (\\wsl.localhost\<distro>\home\...).
function Get-WslUnc([string]$LinuxPath) {
  return "\\wsl.localhost\$WslDistro" + ($LinuxPath -replace '/', '\')
}

function Build-Native {
  if (-not $WslRepo.StartsWith('/')) { throw "-WslRepo must be an absolute Linux path, e.g. /home/david/src/Dena.emu" }
  $here = Get-Commit
  $there = (& wsl.exe -d $WslDistro --cd $WslRepo -- git rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $there) { throw "no git checkout at $WslRepo in WSL $WslDistro" }
  if ("$there".Trim() -ne $here) {
    Write-Warning "WSL checkout is at $("$there".Trim()), this checkout at ${here}: the DLLs may not match the app"
  }
  Write-Step "dena_host.dll (MinGW-w64, WSL $WslDistro)"
  $hostCmd = 'cmake -S host/desktop -B build/desktop-win64 -G Ninja -DCMAKE_BUILD_TYPE=Release ' +
    '-DCMAKE_TOOLCHAIN_FILE="$PWD/host/desktop/cmake/mingw-w64-x86_64.cmake" && ninja -C build/desktop-win64'
  Invoke-Checked 'wsl.exe' @('-d', $WslDistro, '--cd', $WslRepo, '--', 'bash', '-lc', $hostCmd)
  Write-Step 'win64 cores (cores/build-desktop.sh win64)'
  # A core that fails is left out of the release (see the notes), so the
  # exit code only gets a warning here.
  & wsl.exe -d $WslDistro --cd $WslRepo -- bash -lc 'bash cores/build-desktop.sh win64'
  if ($LASTEXITCODE -ne 0) { Write-Warning 'some cores failed to build; they will be missing from the release' }
  if (-not $SkipDolphin) {
    # Dolphin is the one core built with MSVC (docs/dev/desktop-cores.md),
    # from this Windows checkout into the WSL cores folder.
    Write-Step 'win64 Dolphin core (cores\dolphin\build-msvc.ps1, MSVC)'
    try {
      & (Join-Path $Root 'cores\dolphin\build-msvc.ps1') -OutDir (Join-Path (Get-WslUnc $WslRepo) 'cores\build\win64')
    } catch {
      Write-Warning "Dolphin did not build: $_ (GameCube and Wii will be missing from the release)"
    }
  }
  # LRPS2 builds with MSVC only (docs/specs/ps2.md), here in Windows; the DLL
  # joins the WSL-built cores.
  Write-Step 'pcsx2_libretro.dll (cores\lrps2\build-msvc.ps1, MSVC)'
  try {
    & (Join-Path $Root 'cores\lrps2\build-msvc.ps1') -OutDir (Get-WslUnc "$WslRepo/cores/build/win64")
  } catch {
    Write-Warning "LRPS2 failed to build ($_); PS2 will be missing from the release"
  }
}

function Find-Iscc {
  if ($Iscc) {
    if (-not (Test-Path -LiteralPath $Iscc)) { throw "no ISCC.exe at $Iscc" }
    return $Iscc
  }
  $cmd = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @()
  foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, (Join-Path "$env:LOCALAPPDATA" 'Programs'))) {
    if ($base) { $candidates += (Join-Path $base 'Inno Setup 6\ISCC.exe') }
  }
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  return $null
}

function Find-VcRuntimeDir {
  $vswhere = Join-Path "${env:ProgramFiles(x86)}" 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
  $vs = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  if (-not $vs) { return $null }
  $redist = Join-Path "$vs".Trim() 'VC\Redist\MSVC'
  if (-not (Test-Path -LiteralPath $redist)) { return $null }
  $dirs = Get-ChildItem -LiteralPath $redist -Directory | Sort-Object Name -Descending |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue }
  foreach ($d in $dirs) {
    if (Test-Path -LiteralPath (Join-Path $d.FullName 'vcruntime140.dll')) { return $d.FullName }
  }
  return $null
}

function New-Zip([string]$SourceDir, [string]$ZipPath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
  # includeBaseDirectory: the zip extracts into one Dena.emu folder.
  [System.IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $ZipPath,
    [System.IO.Compression.CompressionLevel]::Optimal, $true)
}

# --- Inputs ---------------------------------------------------------------

$Version = Get-AppVersion
$Commit = Get-Commit
if (-not $OutDir) { $OutDir = Join-Path $Root 'build\release' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$ZipName = "dena-emu-$Version-windows-x64-portable.zip"
$SetupBase = "dena-emu-$Version-windows-x64-setup"
Write-Step "Dena.emu $Version for Windows x64 ($Commit)$(if ($DryRun) { ', dry run' })"

$nativeRoot = $Root
if ($WslRepo) {
  $nativeRoot = Get-WslUnc $WslRepo
  if (-not $DryRun) { Build-Native }
}
$hostPlaceholder = $DryRun -and -not $HostDir
$coresPlaceholder = $DryRun -and -not $CoresDir
if (-not $HostDir) { $HostDir = Join-Path $nativeRoot 'build\desktop-win64' }
if (-not $CoresDir) { $CoresDir = Join-Path $nativeRoot 'cores\build\win64' }

# --- Flutter bundle ---------------------------------------------------------

$bundle = Join-Path $Root 'app\build\windows\x64\runner\Release'
if ($DryRun) {
  $bundle = Join-Path $OutDir 'dryrun\bundle'
  New-CleanDir $bundle
  foreach ($f in @('dena_emu.exe', 'flutter_windows.dll', 'file_selector_windows_plugin.dll',
      'data\icudtl.dat', 'data\app.so', 'data\flutter_assets\NOTICES.Z')) {
    New-Placeholder (Join-Path $bundle $f)
  }
  Write-Host "> flutter build windows --release$(($DartDefine | ForEach-Object { " --dart-define=$_" }) -join '')"
} elseif (-not $SkipFlutter) {
  Write-Step 'flutter build windows --release'
  $flutterArgs = @('build', 'windows', '--release')
  foreach ($d in $DartDefine) { $flutterArgs += "--dart-define=$d" }
  Push-Location (Join-Path $Root 'app')
  try { Invoke-Checked 'flutter' $flutterArgs } finally { Pop-Location }
}
if (-not (Test-Path -LiteralPath (Join-Path $bundle 'dena_emu.exe'))) {
  throw "no Flutter build at $bundle (run without -SkipFlutter)"
}

# --- Stage (the installer's files) -----------------------------------------

Write-Step "Staging $OutDir\stage\Dena.emu"
$stage = Join-Path $OutDir 'stage\Dena.emu'
New-CleanDir $stage
# Everything but cores\: those come from $CoresDir below, so a stale core the
# Flutter install step copied never ships.
Get-ChildItem -LiteralPath $bundle | Where-Object { $_.Name -ne 'cores' } |
  Copy-Item -Destination $stage -Recurse -Force

if ($hostPlaceholder) {
  New-Placeholder (Join-Path $stage 'dena_host.dll')
} else {
  $hostDll = Join-Path $HostDir 'dena_host.dll'
  if (-not (Test-Path -LiteralPath $hostDll)) {
    throw "no dena_host.dll in ${HostDir}: build it per host/desktop/README.md or pass -WslRepo"
  }
  Copy-Item -LiteralPath $hostDll -Destination $stage -Force
}

$coresOut = Join-Path $stage 'cores'
New-Item -ItemType Directory -Path $coresOut -Force | Out-Null
$missing = @()
foreach ($core in $Cores.Keys) {
  if ($coresPlaceholder) {
    New-Placeholder (Join-Path $coresOut $core)
    continue
  }
  $src = Join-Path $CoresDir $core
  if (Test-Path -LiteralPath $src) {
    Copy-Item -LiteralPath $src -Destination $coresOut -Force
  } else {
    $missing += $core
    Write-Warning "missing core $core ($($Cores[$core])): the release ships without it"
  }
}
if ($missing.Count -gt 0 -and $RequireAllCores) {
  throw "missing cores: $($missing -join ', ')"
}
# PPSSPP's support files (fonts, PPGe atlas; docs/specs/psp.md), written by
# cores/ppsspp/build.sh next to the core. The host copies them to the system
# folder on the first PSP start.
$ppssppAssets = Join-Path $CoresDir 'PPSSPP'
if (-not $coresPlaceholder -and (Test-Path -LiteralPath $ppssppAssets)) {
  Copy-Item -LiteralPath $ppssppAssets -Destination $coresOut -Recurse -Force
} elseif (-not $coresPlaceholder -and -not ($missing -contains 'ppsspp_libretro.dll')) {
  Write-Warning 'no cores\PPSSPP support files: PSP system fonts and dialogs will be missing'
}
# Dolphin's Sys folder (docs/specs/gamecube-wii.md), from build-msvc.ps1.
$dolphinAssets = Join-Path $CoresDir 'dolphin-emu'
if (-not $coresPlaceholder -and (Test-Path -LiteralPath $dolphinAssets)) {
  Copy-Item -LiteralPath $dolphinAssets -Destination $coresOut -Recurse -Force
} elseif (-not $coresPlaceholder -and -not ($missing -contains 'dolphin_libretro.dll')) {
  Write-Warning 'no cores\dolphin-emu\Sys: GameCube and Wii games will not start'
}

$vcDir = $null
if (-not $DryRun) { $vcDir = Find-VcRuntimeDir }
foreach ($dll in $VcRuntime) {
  if (Test-Path -LiteralPath (Join-Path $stage $dll)) { continue }
  if ($DryRun) {
    New-Placeholder (Join-Path $stage $dll)
  } elseif ($vcDir) {
    Copy-Item -LiteralPath (Join-Path $vcDir $dll) -Destination $stage -Force
  } else {
    Write-Warning "no Visual C++ runtime found for $dll (vswhere): users without the VC++ redistributable can't start the app"
  }
}

$licDir = Join-Path $stage 'licenses'
New-Item -ItemType Directory -Path $licDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Root 'LICENSE') -Destination (Join-Path $stage 'LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $Root 'docs\licenses.md') -Destination (Join-Path $licDir 'THIRD-PARTY-LICENSES.md') -Force
Set-Content -LiteralPath (Join-Path $stage 'SOURCE.txt') -Value @"
Dena.emu $Version is free software under the GNU General Public License,
version 3 or later (LICENSE.txt). The emulator cores in cores\ are GPL-2.0+,
GPL-3.0, MPL-2.0 and MIT; licenses\THIRD-PARTY-LICENSES.md lists each one
with its exact upstream commit.

Complete source for this build, including the core build scripts:
https://github.com/Denarmo/Dena.emu/tree/$Commit
"@

# --- Portable zip -----------------------------------------------------------

Write-Step $ZipName
$portable = Join-Path $OutDir 'portable\Dena.emu'
New-CleanDir $portable
Get-ChildItem -LiteralPath $stage | Copy-Item -Destination $portable -Recurse -Force
# portable.txt beside the exe keeps every file in Dena\ (app_dirs.dart).
Set-Content -LiteralPath (Join-Path $portable 'portable.txt') -Value @"
This file turns on portable mode: Dena.emu keeps its library, saves, states
and settings in the Dena folder next to it instead of %APPDATA%\Dena.emu.
Put games in Dena\Roms (one folder per system) and BIOS files in Dena\Bios.
Delete this file to use %APPDATA% again.
"@
foreach ($sys in $RomFolders) {
  New-Item -ItemType Directory -Path (Join-Path $portable "Dena\Roms\$sys") -Force | Out-Null
}
New-Item -ItemType Directory -Path (Join-Path $portable 'Dena\Bios') -Force | Out-Null
$zipPath = Join-Path $OutDir $ZipName
New-Zip $portable $zipPath

# --- Installer --------------------------------------------------------------

$setupPath = Join-Path $OutDir "$SetupBase.exe"
$isccArgs = @('/Qp', "/DAppVersion=$Version", "/DSourceDir=$stage", "/DOutputDir=$OutDir",
  "/DOutputBase=$SetupBase", "/DRepoDir=$Root", $IssFile)
$madeSetup = $false
if ($SkipInstaller) {
  Write-Host 'skipping the installer (-SkipInstaller)'
} elseif ($DryRun) {
  Write-Host "> ISCC.exe $($isccArgs -join ' ')"
} else {
  Write-Step "$SetupBase.exe (Inno Setup)"
  $isccExe = Find-Iscc
  if (-not $isccExe) {
    throw 'ISCC.exe not found: install Inno Setup 6.3 or newer (winget install JRSoftware.InnoSetup, or https://jrsoftware.org/isdl.php), pass -Iscc, or use -SkipInstaller'
  }
  Invoke-Checked $isccExe $isccArgs
  $madeSetup = $true
}

# --- Release notes ----------------------------------------------------------

$notesPath = Join-Path $OutDir 'release-notes-windows.md'
$lines = @(
  "## Windows (x64)",
  "",
  "- **Installer:** ``$SetupBase.exe``. Installs for your user only (no admin), adds a Start menu entry; a desktop shortcut and ""Open with"" entries for game files are optional. Your games, saves and settings live in ``%APPDATA%\Dena.emu`` and stay when you uninstall.",
  "- **Portable:** ``$ZipName``. Unzip anywhere (a USB stick works) and run ``dena_emu.exe``. Everything stays in the ``Dena`` folder beside it; put games in ``Dena\Roms\<system>``.",
  "- Windows 10 or 11, 64-bit. A controller plugged in when the app starts opens it fullscreen in controller mode; F11 or Alt+Enter toggles fullscreen.",
  "- Windows SmartScreen may warn because the files are not code-signed yet: More info > Run anyway.",
  "",
  "### Playing through Steam (Big Picture, Steam Deck dock)",
  "",
  "1. Steam > Games > Add a Non-Steam Game to My Library > Browse > pick ``dena_emu.exe`` (installer: ``%LOCALAPPDATA%\Programs\Dena.emu``; portable: your unzipped folder). Launch options: none needed.",
  "2. In the shortcut's Controller settings choose the ""Gamepad"" layout, not ""Keyboard and Mouse"", so Steam Input passes the pad through.",
  "3. To get gyro straight from the controller (DualSense, Switch Pro), disable Steam Input for the shortcut.",
  ""
)
if ($missing.Count -gt 0) {
  $lines += @("### Not in this build", "")
  foreach ($core in $missing) { $lines += "- $($Cores[$core]): the core did not build for Windows yet." }
  $lines += ""
}
$lines += @(
  "### Known",
  "",
  "- PSP video cutscenes are black (PPSSPP is built without FFmpeg on Windows).",
  "- Saturn and PS2 games need the BIOS from your own console; GameCube, Wii and Dreamcast start without one.",
  "",
  "### SHA-256",
  "",
  '```'
)
$lines += "$((Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLower())  $ZipName"
if ($madeSetup) { $lines += "$((Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLower())  $SetupBase.exe" }
$lines += '```'
Set-Content -LiteralPath $notesPath -Value $lines -Encoding UTF8

Write-Step 'Release notes'
Get-Content -LiteralPath $notesPath | ForEach-Object { Write-Host $_ }
Write-Step 'Done'
Write-Host "  $zipPath"
if ($madeSetup) { Write-Host "  $setupPath" }
Write-Host "  $notesPath"
if ($missing.Count -gt 0) { Write-Host "  missing cores: $($missing -join ', ')" }
