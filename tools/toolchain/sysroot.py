#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the aarch64 Linux sysroot (headers and link-only libraries) from pinned Debian packages (spec: docs/specs/toolchain-linux.md)."""

import argparse
import hashlib
import io
import os
import posixpath
import sys
import tarfile
import urllib.request

MIRROR = "https://deb.debian.org/debian/"

# (package name, path under the pool, sha256 of the .deb). Runtime packages
# come first so the -dev packages' libfoo.so links find their targets;
# libgl-dev brings KHR/khrplatform.h.
PACKAGES = [
    ("libdrm2",
     "pool/main/libd/libdrm/libdrm2_2.4.114-1+b1_arm64.deb",
     "f5f15a46d02cf5d9fa52d4f1c54b8cf80c398711ad771a9938b12399b8d8090c"),
    ("libgbm1",
     "pool/main/m/mesa/libgbm1_22.3.6-1+deb12u2_arm64.deb",
     "f5c8fdddbf365259d74af270fb10f30d7fddb3fbe7b2ff62f0fdd556f8db0dc8"),
    ("libglvnd0",
     "pool/main/libg/libglvnd/libglvnd0_1.6.0-1_arm64.deb",
     "d5063205fab5322ee686f33f87c6315b3fcd1335ea4e7bc8202b48ed4f9c9e83"),
    ("libegl1",
     "pool/main/libg/libglvnd/libegl1_1.6.0-1_arm64.deb",
     "707097a275155c600e2e9251c4ee7cdfdb2d8f50a678a850a2526a7bc9664166"),
    ("libgles2",
     "pool/main/libg/libglvnd/libgles2_1.6.0-1_arm64.deb",
     "efeb2717380f8411d66b3f669bb99bbd83ff09db3d4a1661533aa31af659608c"),
    ("libasound2",
     "pool/main/a/alsa-lib/libasound2_1.2.8-1+b1_arm64.deb",
     "9fa889400fcee4b92c8f4a2fafbb7f2cd33444d9ec1665a71002ab67c06114bb"),
    ("libdrm-dev",
     "pool/main/libd/libdrm/libdrm-dev_2.4.114-1+b1_arm64.deb",
     "26d7d0dcbbda8ed023b57989e0fca7f0ff8372daaf654daf8b3a362557be5e21"),
    ("libgbm-dev",
     "pool/main/m/mesa/libgbm-dev_22.3.6-1+deb12u2_arm64.deb",
     "0ab863c32efc2519db45bacb9a1f916455d9db2c3ba10ea4797e56eda9dcd7be"),
    ("libegl-dev",
     "pool/main/libg/libglvnd/libegl-dev_1.6.0-1_arm64.deb",
     "8a3004f892785a5fa4c9f969c116f567a36d1c8e9b3d5fd0403055151e36c7d3"),
    ("libgles-dev",
     "pool/main/libg/libglvnd/libgles-dev_1.6.0-1_arm64.deb",
     "941e9963d64479544691f7183fe0eeae32b53b633df71c4c51263517ab2ea8f3"),
    ("libgl-dev",
     "pool/main/libg/libglvnd/libgl-dev_1.6.0-1_arm64.deb",
     "56add9e710c072cf56504beed50a639f9f7c64f4e31e66958fa65a566084888c"),
    ("libasound2-dev",
     "pool/main/a/alsa-lib/libasound2-dev_1.2.8-1+b1_arm64.deb",
     "263668e5ce831d3a8426bd342beba7e94925e893a4a5a285252b8f3ed6b3f5ee"),
]

_AR_MAGIC = b"!<arch>\n"
_AR_HEADER_SIZE = 60

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_DEST = os.path.join(_HERE, "sysroot")
_DEFAULT_CACHE = os.path.join(_HERE, "sysroot-cache")

# Directories inside a .deb we unpack (relative, no leading "./").
WANTED_PREFIXES = (
    "usr/include/",
    "usr/lib/aarch64-linux-gnu/",
)


def read_ar(data: bytes) -> list:
    """Parse a Unix ar archive into a list of (name, bytes) members."""
    if data[:len(_AR_MAGIC)] != _AR_MAGIC:
        raise ValueError("not an ar archive (bad magic)")
    members = []
    offset = len(_AR_MAGIC)
    while offset < len(data):
        if offset + _AR_HEADER_SIZE > len(data):
            raise ValueError("truncated ar header")
        header = data[offset:offset + _AR_HEADER_SIZE]
        if header[58:60] != b"`\n":
            raise ValueError("bad ar header terminator")
        name = header[0:16].rstrip(b"/ ").decode("ascii", "replace")
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError:
            raise ValueError("bad ar member size for %r" % name)
        start = offset + _AR_HEADER_SIZE
        end = start + size
        if end > len(data):
            raise ValueError("truncated ar member %r" % name)
        members.append((name, data[start:end]))
        offset = end + (size % 2)
    return members


def _safe_norm(name: str):
    """Return the archive-relative path of *name*, or None if it is unsafe."""
    path = name.replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    if path.startswith("/"):
        return None
    norm = posixpath.normpath(path)
    if norm in (".", "") or norm == ".." or norm.startswith("../"):
        return None
    return norm


def _write_file(dest: str, rel: str, content: bytes) -> None:
    target = os.path.join(dest, *rel.split("/"))
    parent = os.path.dirname(target)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(target, "wb") as handle:
        handle.write(content)


def _resolve_symlink(link_rel, target, regular, symlinks):
    """Follow *link_rel*'s chain and return a regular member path, or None."""
    seen = set()
    current = posixpath.normpath(
        posixpath.join(posixpath.dirname(link_rel), target))
    while True:
        if current in regular:
            return current
        if current in symlinks and current not in seen:
            seen.add(current)
            current = posixpath.normpath(
                posixpath.join(posixpath.dirname(current), symlinks[current]))
            continue
        return None


def extract_deb(data: bytes, dest: str) -> list:
    """Unpack headers and link-only libraries from a .deb into *dest*."""
    payload = None
    for name, blob in read_ar(data):
        if name.startswith("data.tar"):
            if name.endswith(".zst"):
                raise ValueError("zstd not supported")
            payload = blob
            break
    if payload is None:
        raise ValueError("no data.tar member in archive")

    written = []
    regular = {}
    symlinks = {}
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:*") as tar:
        for member in tar:
            if member.isfile():
                is_link = False
            elif member.issym():
                is_link = True
            else:
                continue
            rel = _safe_norm(member.name)
            if rel is None:
                continue
            if not rel.startswith(WANTED_PREFIXES):
                continue
            if is_link:
                symlinks[rel] = member.linkname
                continue
            extracted = tar.extractfile(member)
            content = extracted.read() if extracted is not None else b""
            _write_file(dest, rel, content)
            regular[rel] = content
            written.append(rel)

    # Windows has no usable symlinks, so a link is a copy of its target.
    for link_rel, target in symlinks.items():
        resolved = _resolve_symlink(link_rel, target, regular, symlinks)
        if resolved is not None:
            content = regular[resolved]
        else:
            # A -dev package's link to a library from a package unpacked
            # earlier (PACKAGES lists runtime packages first).
            existing = _safe_norm(posixpath.join(posixpath.dirname(link_rel), target))
            path = existing and os.path.join(dest, *existing.split("/"))
            if not path or not os.path.isfile(path):
                continue
            with open(path, "rb") as handle:
                content = handle.read()
        _write_file(dest, link_rel, content)
        written.append(link_rel)

    return written


def fetch(url: str) -> bytes:
    """Download *url* and return its body."""
    with urllib.request.urlopen(url) as response:
        return response.read()


def _stamp() -> str:
    """Hash the pinned package hashes, so a changed list invalidates a build."""
    joined = "".join(sha256 for _name, _path, sha256 in PACKAGES)
    return hashlib.sha256(joined.encode("ascii")).hexdigest()


def build(dest: str, cache: str, fetcher=fetch) -> None:
    """Fetch, verify and unpack every pinned package into *dest*."""
    os.makedirs(dest, exist_ok=True)
    os.makedirs(cache, exist_ok=True)

    marker = os.path.join(dest, ".dena-sysroot")
    stamp = _stamp()
    if os.path.isfile(marker):
        with open(marker, "r", encoding="ascii") as handle:
            if handle.read().strip() == stamp:
                return

    for name, pool_path, sha256 in PACKAGES:
        cached = os.path.join(cache, os.path.basename(pool_path))
        payload = None
        if os.path.isfile(cached):
            with open(cached, "rb") as handle:
                payload = handle.read()
            if hashlib.sha256(payload).hexdigest() != sha256:
                payload = None
        if payload is None:
            payload = fetcher(MIRROR + pool_path)
            actual = hashlib.sha256(payload).hexdigest()
            if actual != sha256:
                raise RuntimeError(
                    "checksum mismatch for %s: expected %s, got %s"
                    % (name, sha256, actual))
            with open(cached, "wb") as handle:
                handle.write(payload)
        extract_deb(payload, dest)

    with open(marker, "w", encoding="ascii") as handle:
        handle.write(stamp)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="sysroot.py", description=__doc__.splitlines()[0])
    parser.add_argument("--dest", default=_DEFAULT_DEST,
                        help="where to unpack the sysroot (default: %(default)s)")
    parser.add_argument("--cache", default=_DEFAULT_CACHE,
                        help="where to cache the .deb files (default: %(default)s)")
    args = parser.parse_args(argv)

    build(args.dest, args.cache)
    print(args.dest)
    return 0


if __name__ == '__main__':
    sys.exit(main())
