#!/usr/bin/env bash
# Builds the Beetle PSX HW libretro core (PlayStation, GPL-2.0-or-later) from a
# pinned commit: the desktop PlayStation core (PCSX ReARMed stays on ARM).
# HAVE_HW=1 gives the OpenGL and Vulkan renderers (internal resolution up to
# 16x, PGXP); Lightrec is its x86_64 dynarec. Desktop only for now.
# Usage: cores/beetle_psx/build.sh [--dry-run] <host|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/mednafen_psx_hw_libretro.{so,dll}. Builds: docs/dev/desktop-cores.md
NAME=mednafen_psx_hw
REPO=https://github.com/libretro/beetle-psx-libretro.git
COMMIT=6454af0a690a5e004211bce8e62286bd18acd87d
HOST_DIR=.
HOST_MAKE="HAVE_HW=1"
JNI_DIR=.
source "$(dirname "$0")/../libretro-make.sh"
