#!/usr/bin/env bash
# Builds the FCEUmm libretro core (NES, GPL-2.0) from a pinned commit.
# Usage: cores/fceumm/build.sh <host|android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/fceumm_libretro.{so,dll,dylib}. Spec: docs/specs/cores-m2.md
NAME=fceumm
REPO=https://github.com/libretro/libretro-fceumm.git
COMMIT=ac0d00a7fc01166f84c7bac01d1084ebfd2b865e
HOST_DIR=.
HOST_MAKE="-f Makefile.libretro"
JNI_DIR=.
source "$(dirname "$0")/../libretro-make.sh"
