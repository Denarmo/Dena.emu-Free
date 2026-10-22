# SPDX-License-Identifier: GPL-3.0-or-later
<#
.SYNOPSIS
Builds the Dolphin libretro core (GameCube, Wii) for Windows x86_64 with MSVC
(docs/dev/desktop-cores.md, "Dolphin on Windows").

.DESCRIPTION
Runs on DENA-PC from a Windows checkout (PowerShell 5.1 or 7). Needs Visual
Studio 2022 (or its Build Tools) with "Desktop development with C++" and a
Windows 10/11 SDK, CMake 3.25 or newer (the one Visual Studio ships is fine)
and git. Same pinned commit and patches as cores/dolphin/build.sh; the
Visual Studio generator, x64, Release, static runtime (/MT), so the DLL needs
no redistributable.

Writes <OutDir>\dolphin_libretro.dll and <OutDir>\dolphin-emu\Sys (the core's
data files, with a dena-assets.txt stamp; the host copies them to
<system>\dolphin-emu on the first start). Sources and objects stay in
cores\build\src\dolphin and cores\build\obj\dolphin-msvc of this checkout.

.EXAMPLE
cores\dolphin\build-msvc.ps1

.EXAMPLE
cores\dolphin\build-msvc.ps1 -OutDir \\wsl.localhost\Debian\home\david\src\Dena.emu\cores\build\win64

.EXAMPLE
cores\dolphin\build-msvc.ps1 -DryRun
#>
[CmdletBinding()]
param(
  # Where the DLL and dolphin-emu\ go (default: cores\build\win64).
  [string]$OutDir,
  # Visual Studio generator name.
  [string]$Generator = 'Visual Studio 17 2022',
  # Parallel compile jobs (default: all logical processors).
  [int]$Jobs = 0,
  # Print every command, change nothing.
  [switch]$DryRun
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

# Keep in step with cores/dolphin/build.sh and docs/licenses.md.
$Repo = 'https://github.com/libretro/dolphin.git'
$Commit = '5466da350f2fd143ee3e7b921e8c33aee64f7065'
$SkipSubmodules = @('Externals/Qt', 'Externals/FFmpeg-bin', 'Externals/gtest',
  'Externals/libadrenotools')

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutDir) { $OutDir = Join-Path $Root 'cores\build\win64' }
$Src = Join-Path $Root 'cores\build\src\dolphin'
$Bld = Join-Path $Root 'cores\build\obj\dolphin-msvc'
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

function Invoke-Step {
  param([string]$Exe, [string[]]$Arguments)
  Write-Host "+ $Exe $($Arguments -join ' ')"
  if ($DryRun) { return }
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

# True when git succeeds; its stderr is dropped (PowerShell 5.1 turns native
# stderr into errors under 'Stop').
function Test-Git {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & git @args 2>$null | Out-Null; return $LASTEXITCODE -eq 0 } finally { $ErrorActionPreference = $old }
}

function Find-CMake {
  $cm = Get-Command cmake -ErrorAction SilentlyContinue
  if ($cm) { return $cm.Source }
  # The CMake Visual Studio installs with the C++ workload.
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs) {
      $bundled = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
      if (Test-Path -LiteralPath $bundled) { return $bundled }
    }
  }
  if ($DryRun) { return 'cmake' }
  throw 'no cmake: install Visual Studio 2022 with "Desktop development with C++" (docs/dev/desktop-cores.md)'
}

# --- Source -----------------------------------------------------------------

if ($DryRun) {
  Write-Host "+ fetch Dolphin $Commit with its submodules into $Src and apply cores\dolphin\patches"
} else {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'no git on the PATH' }
  if (-not (Test-Path -LiteralPath (Join-Path $Src '.git'))) {
    Invoke-Step git @('init', '-q', $Src)
    Invoke-Step git @('-C', $Src, 'remote', 'add', 'origin', $Repo)
  }
  if (-not (Test-Git -C $Src cat-file -e "$Commit^{commit}") -or
      (& git -C $Src rev-parse HEAD) -ne $Commit) {
    Invoke-Step git @('-C', $Src, 'fetch', '-q', '--depth', '1', 'origin', $Commit)
    Invoke-Step git @('-C', $Src, 'checkout', '-q', '--detach', 'FETCH_HEAD')
  }
  if ((& git -C $Src rev-parse HEAD) -ne $Commit) { throw "dolphin checkout is not $Commit" }
  # Long paths: some Externals go past MAX_PATH.
  Invoke-Step git @('-C', $Src, 'config', 'core.longpaths', 'true')
  $subs = & git -C $Src config -f .gitmodules --get-regexp '\.path$' |
    ForEach-Object { ($_ -split ' ', 2)[1] } |
    Where-Object { $SkipSubmodules -notcontains $_ }
  Invoke-Step git (@('-C', $Src, 'submodule', 'update', '--init', '--recursive', '--depth', '1', '-q') + $subs)
  foreach ($patch in Get-ChildItem -Path (Join-Path $PSScriptRoot 'patches') -Filter '*.patch' -ErrorAction SilentlyContinue) {
    if (Test-Git -C $Src apply --check --ignore-whitespace $patch.FullName) {
      Invoke-Step git @('-C', $Src, 'apply', '--ignore-whitespace', $patch.FullName)
    } elseif (-not (Test-Git -C $Src apply --reverse --check --ignore-whitespace $patch.FullName)) {
      throw "cannot apply $($patch.Name)"
    }
  }
}

# --- Build ------------------------------------------------------------------

$cmake = Find-CMake
# The upstream MSVC CI configuration, plus: static runtime for C as well as
# C++, everything bundled, no GBA link core, tests, updater or analytics.
Invoke-Step $cmake @('-S', $Src, '-B', $Bld, '-G', $Generator, '-A', 'x64',
  '-DLIBRETRO=ON', '-DCMAKE_BUILD_TYPE=Release',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
  '-DUSE_SYSTEM_LIBS=OFF', '-DUSE_MGBA=ON', '-DENABLE_TESTS=OFF', '-DENABLE_QT=OFF',
  '-DENABLE_AUTOUPDATE=OFF', '-DENABLE_ANALYTICS=OFF', '-DUSE_DISCORD_PRESENCE=OFF',
  '-DUSE_UPNP=OFF', '-DENCODE_FRAMEDUMPS=OFF', '-DENABLE_VULKAN=ON',
  '-DRC_CLIENT_SUPPORTS_RAINTEGRATION=OFF')
Invoke-Step $cmake @('--build', $Bld, '--config', 'Release', '--parallel', "$Jobs",
  '--target', 'dolphin_libretro')

# --- Output -----------------------------------------------------------------

$dll = Join-Path $Bld 'Release\dolphin_libretro.dll'
if (-not $DryRun -and -not (Test-Path -LiteralPath $dll)) {
  $found = Get-ChildItem -Path $Bld -Recurse -Filter 'dolphin_libretro.dll' | Select-Object -First 1
  if (-not $found) { throw "dolphin_libretro.dll not found in $Bld" }
  $dll = $found.FullName
}
$assets = Join-Path $OutDir 'dolphin-emu'
Write-Host "+ copy $dll and $Src\Data\Sys to $OutDir"
if (-not $DryRun) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
  Copy-Item -LiteralPath $dll -Destination (Join-Path $OutDir 'dolphin_libretro.dll') -Force
  if (Test-Path -LiteralPath $assets) { Remove-Item -LiteralPath $assets -Recurse -Force }
  New-Item -ItemType Directory -Path $assets -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $Src 'Data\Sys') -Destination (Join-Path $assets 'Sys') -Recurse -Force
  [IO.File]::WriteAllText((Join-Path $assets 'dena-assets.txt'), $Commit.Substring(0, 12))
  # The DLL must not need the Visual C++ redistributable (static /MT).
  $dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
  if ($dumpbin) {
    $deps = & $dumpbin.Source /dependents (Join-Path $OutDir 'dolphin_libretro.dll') |
      Where-Object { $_ -match '^\s+(msvcp|vcruntime)\d*.*\.dll' }
    if ($deps) { throw "dolphin_libretro.dll needs the Visual C++ runtime: $($deps -join ', ') (static /MT expected)" }
  }
}
Write-Host "built $(Join-Path $OutDir 'dolphin_libretro.dll')"
