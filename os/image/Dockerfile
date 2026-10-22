# SPDX-License-Identifier: GPL-3.0-or-later
# Build environment for the single-card image (docs/specs/single-card.md).
# Everything runs locally; from the repo root:
#   docker build -t dena-image os/image
#   docker run --rm -v "$PWD:/src" -w /src dena-image os/image/build.sh --test
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates cpio curl debian-archive-keyring \
      device-tree-compiler dosfstools fdisk flex gcc-aarch64-linux-gnu git ipxe-qemu \
      libc6-dev-arm64-cross \
      libgnutls28-dev libssl-dev mmdebstrap mtools patch python3 python3-dev \
      python3-pyelftools python3-setuptools qemu-system-arm squashfs-tools swig \
      uuid-dev xz-utils \
    && rm -rf /var/lib/apt/lists/*
# The checkout is mounted from the host and owned by another user.
RUN git config --system --add safe.directory '*'
