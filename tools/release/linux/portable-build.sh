#!/usr/bin/env bash
# Builds the portable tar.gz's binaries (docs/dev/release-linux.md): the
# linux-x86_64 cores, libdena_host.so and the Flutter release bundle, all
# against the older glibc of the portable SDK (portable_sdk= in
# cores/desktop-runtime.txt). build-linux.sh runs this inside that SDK, in its
# own copy of the repo, so nothing mixes with the Flatpak's 26.08 build.
#
# Usage: portable-build.sh <repo copy> <skip cores: 0|1> [flutter build args]
# Environment: DENA_FLUTTER_ROOT (Flutter SDK), DENA_LLVM_BIN (clang for the
# Flutter runner, from the SDK's LLVM extension).
set -euo pipefail

src="${1:?usage: portable-build.sh <repo copy> <0|1> [flutter args]}"
skip_cores="${2:?usage: portable-build.sh <repo copy> <0|1> [flutter args]}"
shift 2
export PATH="${DENA_LLVM_BIN:?}:${DENA_FLUTTER_ROOT:?}/bin:$PATH"

for tool in gcc clang clang++ cmake ninja pkg-config flutter; do
  command -v "$tool" >/dev/null || { echo "portable-build: no $tool in the SDK (docs/dev/release-linux.md, Setup)" >&2; exit 1; }
done
echo "portable SDK: $(ldd --version | head -n1), $(gcc --version | head -n1)"

if [ "$skip_cores" = 0 ]; then
  echo; echo "=== Building the portable linux-x86_64 cores"
  bash "$src/cores/build-desktop.sh" --native linux-x86_64
fi

# Where app/linux/CMakeLists.txt looks for it (DENA_HOST_DIR).
echo; echo "=== Building the portable libdena_host.so"
cmake -S "$src/host/desktop" -B "$src/build/desktop-linux" -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C "$src/build/desktop-linux"
ctest --test-dir "$src/build/desktop-linux" --output-on-failure

echo; echo "=== Running flutter build linux --release (portable)"
cd "$src/app"
flutter build linux --release "$@"
