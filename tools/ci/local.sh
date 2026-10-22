#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the CI checks on this machine (spec: docs/specs/ci.md).
# GitHub Actions is manual-only; this script is the gate before pushing.
#
# Usage: tools/ci/local.sh [flutter|host|rig|licenses|android]...   (default: all)
# The Android step runs only when ANDROID_HOME (or ANDROID_SDK_ROOT) is set.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
steps=("$@")
[ ${#steps[@]} -eq 0 ] && steps=(licenses rig flutter host linux os android)

# On Windows, python3 may be the Microsoft Store stub: probe it.
py=python3
"$py" -c "" >/dev/null 2>&1 || py=python

failed=()
# Each step runs in a subshell with errexit on: inside `if`, bash ignores -e,
# so a failed build could otherwise fall through to stale test binaries.
run() {
  echo "=== $1"
  set +e
  (set -e; "${@:2}")
  local rc=$?
  set -e
  [ $rc -eq 0 ] || failed+=("$1")
}

licenses() { (cd app && flutter pub get >/dev/null) && "$py" tools/licenses/check_licenses.py; }

rig() {
  "$py" -m unittest discover -s tools/rig && "$py" -m unittest discover -s tools/toolchain &&
    "$py" -m unittest discover -s tools/release
}
os_checks() { "$py" -m unittest discover -s os/tests; }

flutter_checks() {
  cd app
  flutter pub get >/dev/null
  dart format --output=none --set-exit-if-changed lib test
  flutter analyze
  flutter test
}

host() {
  local gen=()
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) gen=(-G "MinGW Makefiles") ;; esac
  local cores_dir=()
  [ -d cores/build/host ] && cores_dir=(-DDENA_CORES_DIR="$root/cores/build/host")
  cmake -S host -B host/build "${gen[@]}" -DCMAKE_BUILD_TYPE=Release "${cores_dir[@]}" >/dev/null
  cmake --build host/build --parallel
  # Cores this machine can't build (bsnes on Windows) are skipped, not failed.
  local skip=() core sys
  for pair in mgba:gba fceumm:nes bsnes:snes fake08:pico8; do
    core="${pair%%:*}" sys="${pair#*:}"
    if ! ls cores/build/host/"$core"_libretro.* >/dev/null 2>&1; then
      echo "skipping $sys goldens: no $core core in cores/build/host"
      skip+=("_$sys\$")
    fi
  done
  local exclude=()
  [ ${#skip[@]} -gt 0 ] && exclude=(-E "$(IFS='|'; echo "${skip[*]}")")
  ctest --test-dir host/build --output-on-failure "${exclude[@]}"
}

linux() {
  # Handheld layer (docs/specs/m4-plan.md): the parts that build on any host.
  local gen=()
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) gen=(-G "MinGW Makefiles") ;; esac
  cmake -S shells/linux -B shells/linux/build "${gen[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build shells/linux/build --parallel
  ctest --test-dir shells/linux/build --output-on-failure
  # Device builds: aarch64 Linux with Zig (toolchain-linux.md), else a
  # syntax check of the device-only sources against the NDK's Linux headers.
  local zig
  if zig="$(bash tools/toolchain/zig.sh path 2>/dev/null)"; then
    # The launcher needs the sysroot (tools/toolchain/sysroot.py).
    local sysroot=() launcher=()
    if [ -f tools/toolchain/sysroot/.dena-sysroot ]; then
      sysroot=(-DDENA_SYSROOT="$root/tools/toolchain/sysroot")
      launcher=(shells/linux/build-aarch64/dena-launcher)
    fi
    cross shells/linux "$zig" "${sysroot[@]}"
    cross host "$zig"
    "$py" tools/toolchain/elfcheck.py shells/linux/build-aarch64/dena-powerd \
      shells/linux/build-aarch64/dena-keytest host/build-aarch64/dena-harness \
      host/build-aarch64/dena_testcore.so "${launcher[@]}"
    # Cores are built by hand (cores/<name>/build.sh linux-aarch64).
    if ls cores/build/linux-aarch64/*.so >/dev/null 2>&1; then
      "$py" tools/toolchain/elfcheck.py cores/build/linux-aarch64/*.so
    fi
    return 0
  fi
  echo "no Zig (tools/toolchain/zig.sh install): syntax check only"
  local ndk="${ANDROID_NDK_HOME:-}"
  local sdk="${ANDROID_HOME:-${LOCALAPPDATA:-}/Android/Sdk}"
  if [ -z "$ndk" ] && [ -d "$sdk/ndk" ]; then ndk="$sdk/ndk/$(ls "$sdk/ndk" | sort -V | tail -1)"; fi
  local cc
  cc="$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/clang 2>/dev/null | head -1)"
  [ -n "$cc" ] || cc="$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/clang.exe 2>/dev/null | head -1)"
  if [ -n "$cc" ]; then
    for f in shells/linux/src/*.c; do
      "$cc" --target=aarch64-linux-android28 -std=c11 -Wall -Wextra -Werror \
        -fsyntax-only -Ishells/linux/include -Ishells/linux/build/gen "$f"
    done
    echo "device sources compile-checked"
  else
    echo "no NDK: skipping the device-source compile check"
  fi
}

# Cross-builds a CMake project for aarch64 Linux into <dir>/build-aarch64.
cross() {
  local gen=()
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) gen=(-G "MinGW Makefiles") ;; esac
  cmake -S "$1" -B "$1/build-aarch64" "${gen[@]}" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF -DCMAKE_TOOLCHAIN_FILE="$root/tools/toolchain/aarch64-linux.cmake" \
    -DDENA_ZIG="$2" "${@:3}" >/dev/null
  cmake --build "$1/build-aarch64" --parallel
}

android() {
  # Default SDK location used by sdkmanager/Android Studio on Windows.
  if [ -z "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ] && [ -n "${LOCALAPPDATA:-}" ]      && [ -d "$LOCALAPPDATA/Android/Sdk" ]; then
    export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
  fi
  if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME/ndk" ]; then
    ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$(ls "$ANDROID_HOME/ndk" | sort -V | tail -1)"
    export ANDROID_NDK_HOME
  fi
  if [ -z "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]; then
    echo "skipped: no Android SDK (set ANDROID_HOME)"
    return 0
  fi
  # Windows: build the cores' CMake projects with the SDK's Ninja, not MSBuild.
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*)
    local sdk_cmake
    sdk_cmake="$(ls -d "${ANDROID_HOME:-$ANDROID_SDK_ROOT}"/cmake/*/bin 2>/dev/null | sort -V | tail -1)"
    [ -n "$sdk_cmake" ] && export PATH="$sdk_cmake:$PATH"
    export CMAKE_GENERATOR=Ninja ;;
  esac
  (cd app && flutter build apk --debug)
  (cd app/android && ./gradlew :dena_android:testDebugUnitTest)
}

for s in "${steps[@]}"; do
  case "$s" in
    licenses) run licenses licenses ;;
    rig) run rig rig ;;
    flutter) run flutter bash -c "$(declare -f flutter_checks); flutter_checks" ;;
    host) run host host ;;
    linux) run linux linux ;;
    os) run os os_checks ;;
    android) run android android ;;
    *) echo "unknown step: $s" >&2; exit 2 ;;
  esac
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "all local checks passed"
