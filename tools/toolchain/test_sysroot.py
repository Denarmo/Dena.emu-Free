#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for sysroot.py (synthetic .deb files, no network needed)."""

import hashlib
import io
import os
import sys
import tarfile
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sysroot  # noqa: E402  (path set up just above)

FOO_H = b"#define FOO 1\n"
LIB_SO_1 = b"\x7fELF fake shared library\n"
DOC = b"documentation\n"
EVIL = b"evil\n"


def make_ar(members):
    """Assemble a Unix ar archive from (name, payload) pairs."""
    out = bytearray(b"!<arch>\n")
    for name, payload in members:
        header = (name + "/").ljust(16) + "0".ljust(12) + "0".ljust(6) + \
            "0".ljust(6) + "100644".ljust(8) + str(len(payload)).ljust(10) + "`\n"
        out.extend(header.encode("ascii"))
        out.extend(payload)
        if len(payload) % 2:
            out.extend(b"\n")
    return bytes(out)


def make_tar_xz(entries):
    """Build a tar.xz blob; entries are (kind, name, data/linkname)."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:xz") as tar:
        for kind, name, value in entries:
            info = tarfile.TarInfo(name)
            if kind == "file":
                info.size = len(value)
                tar.addfile(info, io.BytesIO(value))
            elif kind == "sym":
                info.type = tarfile.SYMTYPE
                info.linkname = value
                tar.addfile(info)
            elif kind == "dir":
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
    return buffer.getvalue()


def make_deb(entries):
    """Assemble a minimal Debian package containing the given tar entries."""
    return make_ar([
        ("debian-binary", b"2.0\n"),
        ("control.tar.xz", make_tar_xz([("file", "./control", b"Package: x\n")])),
        ("data.tar.xz", make_tar_xz(entries)),
    ])


def default_entries():
    return [
        ("file", "./usr/include/foo.h", FOO_H),
        ("file", "./usr/lib/aarch64-linux-gnu/libfoo.so.1", LIB_SO_1),
        ("sym", "./usr/lib/aarch64-linux-gnu/libfoo.so", "libfoo.so.1"),
        ("file", "./usr/share/doc/x", DOC),
        ("file", "../evil.h", EVIL),
    ]


class ReadArTests(unittest.TestCase):
    def test_round_trip_and_odd_padding(self):
        members = [
            ("debian-binary", b"2.0\n"),
            ("control.tar.xz", b"x" * 5),  # odd length, needs padding
            ("data.tar.xz", b"y" * 4),
        ]
        self.assertEqual(sysroot.read_ar(make_ar(members)), members)

    def test_bad_magic_raises(self):
        with self.assertRaises(ValueError):
            sysroot.read_ar(b"not an ar archive")

    def test_truncated_raises(self):
        data = make_ar([("debian-binary", b"2.0\n")])
        with self.assertRaises(ValueError):
            sysroot.read_ar(data[:-3])


class ExtractDebTests(unittest.TestCase):
    def test_extracts_wanted_files_and_copies_symlink(self):
        deb = make_deb(default_entries())
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "sysroot")
            written = sysroot.extract_deb(deb, dest)

            with open(os.path.join(dest, "usr", "include", "foo.h"), "rb") as f:
                self.assertEqual(f.read(), FOO_H)
            with open(os.path.join(
                    dest, "usr", "lib", "aarch64-linux-gnu", "libfoo.so.1"),
                    "rb") as f:
                self.assertEqual(f.read(), LIB_SO_1)
            with open(os.path.join(
                    dest, "usr", "lib", "aarch64-linux-gnu", "libfoo.so"),
                    "rb") as f:
                self.assertEqual(f.read(), LIB_SO_1)

            self.assertIn("usr/include/foo.h", written)
            self.assertIn("usr/lib/aarch64-linux-gnu/libfoo.so", written)

    def test_skips_unwanted_and_evil_paths(self):
        deb = make_deb(default_entries())
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "sysroot")
            sysroot.extract_deb(deb, dest)

            self.assertFalse(os.path.exists(
                os.path.join(dest, "usr", "share", "doc", "x")))
            self.assertFalse(os.path.exists(os.path.join(tmp, "evil.h")))
            self.assertFalse(os.path.exists(os.path.join(dest, "..", "evil.h")))

    def test_link_to_a_library_from_an_earlier_package(self):
        runtime = make_deb([
            ("file", "./usr/lib/aarch64-linux-gnu/libfoo.so.1", LIB_SO_1)])
        dev = make_deb([
            ("sym", "./usr/lib/aarch64-linux-gnu/libfoo.so", "libfoo.so.1"),
            ("sym", "./usr/lib/aarch64-linux-gnu/libbar.so", "libbar.so.1")])
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "sysroot")
            sysroot.extract_deb(runtime, dest)
            written = sysroot.extract_deb(dev, dest)
            lib = os.path.join(dest, "usr", "lib", "aarch64-linux-gnu")
            with open(os.path.join(lib, "libfoo.so"), "rb") as f:
                self.assertEqual(f.read(), LIB_SO_1)
            self.assertFalse(os.path.exists(os.path.join(lib, "libbar.so")))
            self.assertEqual(written, ["usr/lib/aarch64-linux-gnu/libfoo.so"])

    def test_zstd_raises(self):
        deb = make_ar([
            ("debian-binary", b"2.0\n"),
            ("data.tar.zst", b"whatever"),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                sysroot.extract_deb(deb, os.path.join(tmp, "sysroot"))


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.deb = make_deb(default_entries())
        self.sha256 = hashlib.sha256(self.deb).hexdigest()
        self.calls = []

        def fetcher(url):
            self.calls.append(url)
            return self.deb

        self.fetcher = fetcher

    def test_build_extracts_and_caches(self):
        package = ("fakepkg", "pool/main/f/fake/fake_1_arm64.deb", self.sha256)
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "sysroot")
            cache = os.path.join(tmp, "cache")
            with unittest.mock.patch.object(sysroot, "PACKAGES", [package]):
                sysroot.build(dest, cache, self.fetcher)
                self.assertTrue(os.path.exists(
                    os.path.join(dest, "usr", "include", "foo.h")))
                self.assertEqual(len(self.calls), 1)
                self.assertTrue(os.path.isfile(os.path.join(
                    cache, "fake_1_arm64.deb")))

                sysroot.build(dest, cache, self.fetcher)
                self.assertEqual(len(self.calls), 1)

    def test_wrong_sha256_raises(self):
        package = ("fakepkg", "pool/main/f/fake/fake_1_arm64.deb", "0" * 64)
        with tempfile.TemporaryDirectory() as tmp:
            with unittest.mock.patch.object(sysroot, "PACKAGES", [package]):
                with self.assertRaises(RuntimeError):
                    sysroot.build(os.path.join(tmp, "sysroot"),
                                  os.path.join(tmp, "cache"), self.fetcher)


if __name__ == '__main__':
    unittest.main()
