#!/usr/bin/env bash
# Builds the Beetle Saturn libretro core (Sega Saturn, GPL-2.0-or-later) from a
# pinned commit. Software renderer, 64-bit hosts only. Desktop only for now.
# Usage: cores/beetle_saturn/build.sh [--dry-run] <host|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/mednafen_saturn_libretro.{so,dll}. Builds: docs/dev/desktop-cores.md
NAME=mednafen_saturn
REPO=https://github.com/libretro/beetle-saturn-libretro.git
COMMIT=faef2779a7568c1734addc4fe63cc76e9fa2566b
HOST_DIR=.
HOST_MAKE=""
JNI_DIR=.
source "$(dirname "$0")/../libretro-make.sh"
