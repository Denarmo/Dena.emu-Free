#!/usr/bin/env bash
# Builds the PCSX ReARMed libretro core (PlayStation, GPL-2.0) from a pinned commit.
# Its HLE BIOS means no BIOS file is needed; a user-supplied one improves compatibility.
# Usage: cores/pcsx_rearmed/build.sh <host|android-arm64-v8a|android-x86_64|linux-aarch64> [out_dir]
# Output: <out_dir>/pcsx_rearmed_libretro.{so,dll,dylib}. Spec: docs/specs/psx.md
NAME=pcsx_rearmed
REPO=https://github.com/libretro/pcsx_rearmed.git
COMMIT=c8816799b50388e61cfe237fe2cdbb7d8175f20a
HOST_DIR=.
HOST_MAKE="-f Makefile.libretro"
# Handhelds: the ARM dynarec (Lightrec is x86-only upstream).
LINUX_MAKE="ARCH=aarch64 DYNAREC=ari64"
# Its version string uses __DATE__, an error under zig cc.
LINUX_CFLAGS="-Wno-date-time"
JNI_DIR=.
# Desktop PlayStation is Beetle PSX HW (cores/beetle_psx), as port-plan.md says.
DESKTOP_SKIP="the x86_64 PlayStation core is Beetle PSX HW (cores/beetle_psx/build.sh)"
source "$(dirname "$0")/../libretro-make.sh"
