#!/usr/bin/env bash
# Builds the fake-08 libretro core (PICO-8 compatible runtime, MIT; bundled
# z8lua MIT) from a pinned commit. Its oval()/ovalfill() come from a
# CC BY-SA 3.0 snippet, so the fixup swaps them for our own (dena_oval.inc).
# The fixup also exposes PICO-8 RAM as libretro system RAM, so the host can
# reach the GPIO mailbox the launcher cart uses (pico8-launcher-cart.md).
# Usage: cores/fake08/build.sh <host|android-arm64-v8a|android-x86_64|linux-aarch64|win64|linux-x86_64> [out_dir]
# Output: <out_dir>/fake08_libretro.{so,dll}. Spec: docs/specs/pico8.md
NAME=fake08
REPO=https://github.com/jtothebell/fake-08.git
COMMIT=814991a2571ad3970e386cef48f3b148aa1c27b9
HOST_DIR=platform/libretro
HOST_MAKE=""
# z8lua is Lua compiled as C++; clang rejects its C++ flags on .c files.
LINUX_CC=c++
JNI_DIR=platform/libretro
ANDROID_MODULE=fake08
fixup_source() {
  local src="$1" gfx="$1/source/graphics.cpp" lr="$1/platform/libretro/libretro.cpp"
  git -C "$src" submodule update --init --depth 1 -q
  if ! grep -q DENA_OVAL "$gfx"; then
    # Drop both functions that follow the snippet's attribution comment.
    awk '
      skip == 0 && $0 ~ /^\/\/https:\/\/stackoverflow\.com\/a\/8448181/ { skip = 1; next }
      skip == 1 && $0 ~ /^}/ { skip = 0; next }
      skip == 0 { print }
    ' "$gfx" > "$gfx.tmp"
    mv "$gfx.tmp" "$gfx"
    printf '\n#include <cmath>\n' >> "$gfx"
    cat "$(dirname "${BASH_SOURCE[0]}")/dena_oval.inc" >> "$gfx"
  fi
  if ! grep -q DENA_SYSRAM "$lr"; then
    # The stubs return nullptr / 0: answer RETRO_MEMORY_SYSTEM_RAM with PicoRam.
    awk '
      /retro_get_memory_data\(unsigned id\)/ { fn = "data" }
      /retro_get_memory_size\(unsigned id\)/ { fn = "size" }
      fn == "data" && /return nullptr;/ {
        print "    if (id == RETRO_MEMORY_SYSTEM_RAM && _memory) return _memory->data; // DENA_SYSRAM"
        fn = ""
      }
      fn == "size" && /return 0;/ {
        print "    if (id == RETRO_MEMORY_SYSTEM_RAM && _memory) return sizeof(_memory->data); // DENA_SYSRAM"
        fn = ""
      }
      { print }
    ' "$lr" > "$lr.tmp"
    mv "$lr.tmp" "$lr"
  fi
}
source "$(dirname "$0")/../libretro-make.sh"
