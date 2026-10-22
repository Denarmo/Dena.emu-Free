#!/usr/bin/env bash
# Builds the bsnes libretro core (SNES, GPL-3.0) from a pinned commit.
# Usage: cores/bsnes/build.sh <host|android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/bsnes_libretro.{so,dll,dylib}. Spec: docs/specs/cores-m2.md
NAME=bsnes
REPO=https://github.com/libretro/bsnes.git
COMMIT=63ee22f7af8f5d1ada295c2c98fd7bf261fa62a7
HOST_DIR=.
HOST_MAKE=""
# nall specializes std::is_signed, which newer libc++ forbids by default.
LINUX_CFLAGS="-Wno-invalid-specialization"
# SameBoy's gb.c calls vasprintf, which MinGW-w64 declares only with
# _GNU_SOURCE; GCC 14 makes the implicit declaration an error.
WIN64_CFLAGS="-D_GNU_SOURCE"
JNI_DIR=bsnes/target-libretro
# nall specialises std::is_signed, which NDK 29+ clang rejects by default.
ANDROID_CPPFLAGS="-Wno-invalid-specialization"
source "$(dirname "$0")/../libretro-make.sh"
