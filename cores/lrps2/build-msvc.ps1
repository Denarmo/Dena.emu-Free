<#
.SYNOPSIS
Builds the LRPS2 libretro core (PlayStation 2, GPL-3.0-or-later) for Windows
x64 with MSVC: pcsx2_libretro.dll (docs/dev/desktop-cores.md, docs/specs/ps2.md).

.DESCRIPTION
Runs on Windows (DENA-PC), never in the cloud. libretro builds LRPS2 for
Windows with MSVC only, so it is the one desktop core that does not come from
the MinGW cross build in WSL (cores/build-desktop.sh win64 skips it).
tools/release/build-windows.ps1 runs this script; it can also run on its own.

Needs Git and Visual Studio 2022 (or its Build Tools) with the "Desktop
development with C++" workload, which brings MSVC, CMake and the Windows SDK.

The source is fetched at the commit pinned in cores/lrps2/build.sh into
cores\build\src\lrps2-msvc (a checkout of its own, so a WSL build of the same
repo never mixes with it) and built in cores\build\obj\lrps2-msvc.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File cores\lrps2\build-msvc.ps1
powershell -File cores\lrps2\build-msvc.ps1 -OutDir \\wsl.localhost\Debian\home\david\src\Dena.emu\cores\build\win64
powershell -File cores\lrps2\build-msvc.ps1 -DryRun
#>
param(
  # Where pcsx2_libretro.dll goes (default: cores\build\win64 of this checkout).
  [string]$OutDir,
  # Parallel compile jobs (default: all logical processors).
  [int]$Jobs = 0,
  # Print the steps, change nothing.
  [switch]$DryRun
)

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$BuildSh = Join-Path $PSScriptRoot 'build.sh'
$Src = Join-Path $Root 'cores\build\src\lrps2-msvc'
$Bld = Join-Path $Root 'cores\build\obj\lrps2-msvc'
if (-not $OutDir) { $OutDir = Join-Path $Root 'cores\build\win64' }
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

# One pin for both builds: REPO= and COMMIT= of build.sh.
function Get-Pin([string]$Name) {
  foreach ($line in Get-Content -LiteralPath $BuildSh) {
    if ($line -match "^$Name=(\S+)") { return $Matches[1] }
  }
  throw "no $Name= line in $BuildSh"
}
$Repo = Get-Pin 'REPO'
$Commit = Get-Pin 'COMMIT'

function Invoke-Step {
  param([string]$Exe, [string[]]$Arguments)
  Write-Host "> $Exe $($Arguments -join ' ')"
  if ($DryRun) { return }
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

# CMake from Visual Studio (vswhere), else the one on PATH.
function Find-CMake {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs) {
      $cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
      if (Test-Path -LiteralPath $cmake) { return $cmake }
    } elseif (-not $DryRun) {
      throw 'no Visual Studio with the C++ x64 tools: install the "Desktop development with C++" workload'
    }
  }
  $cmd = Get-Command 'cmake.exe' -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  if ($DryRun) { return 'cmake.exe' }
  throw 'no CMake: install Visual Studio 2022 with "Desktop development with C++"'
}

Write-Host "=== LRPS2 $Commit (MSVC, x64)"
if (-not (Test-Path -LiteralPath (Join-Path $Src '.git'))) {
  if (-not $DryRun) { New-Item -ItemType Directory -Path $Src -Force | Out-Null }
  Invoke-Step 'git' @('-C', $Src, 'init', '-q')
}
$head = $null
if (-not $DryRun) { $head = (& git -C $Src rev-parse -q --verify HEAD 2>$null) }
if ("$head".Trim() -ne $Commit) {
  Invoke-Step 'git' @('-C', $Src, 'fetch', '-q', '--depth', '1', $Repo, $Commit)
  Invoke-Step 'git' @('-C', $Src, 'checkout', '-q', 'FETCH_HEAD')
}
if (-not $DryRun -and "$(& git -C $Src rev-parse HEAD)".Trim() -ne $Commit) {
  throw "lrps2 checkout is not $Commit"
}

$cmake = Find-CMake
Invoke-Step $cmake @('-S', $Src, '-B', $Bld, '-G', 'Visual Studio 17 2022', '-A', 'x64',
  '-DLIBRETRO=ON', '-DPCAP=OFF', '-DUSE_OPENGL=ON', '-DUSE_VULKAN=ON',
  '-DCMAKE_POLICY_VERSION_MINIMUM=3.18')
Invoke-Step $cmake @('--build', $Bld, '--config', 'Release', '--target', 'pcsx2_libretro',
  '--parallel', "$Jobs")

if ($DryRun) {
  Write-Host "> copy pcsx2_libretro.dll to $OutDir"
  return
}
# The Visual Studio generator puts the DLL under a Release folder of its own.
$dll = Get-ChildItem -LiteralPath $Bld -Recurse -Filter 'pcsx2_libretro.dll' |
  Where-Object { $_.FullName -match '\\Release\\' } | Select-Object -First 1
if (-not $dll) { throw "pcsx2_libretro.dll not found under $Bld" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Copy-Item -LiteralPath $dll.FullName -Destination $OutDir -Force
Write-Host "built $(Join-Path $OutDir 'pcsx2_libretro.dll')"
