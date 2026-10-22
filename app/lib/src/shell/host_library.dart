// SPDX-License-Identifier: GPL-3.0-or-later
// The native library that holds the emulator host's dart:ffi entry points
// (dena_touch_*, dena_set_turbo, dena_ram_*, dena_ra_*, dena_link_*,
// dena_desktop_*). Spec: desktop-shell.md
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'platform_features.dart';

/// Where the host library is for [profile], or null when it is the process
/// itself (the handheld launcher) or there is none. [executable] is
/// `Platform.resolvedExecutable`.
String? hostLibraryPath(
  ShellProfile profile, {
  String? executable,
  String? os,
}) {
  final exe = executable ?? Platform.resolvedExecutable;
  switch (profile) {
    case ShellProfile.android:
      return 'libdena_android.so'; // found by the Android linker
    case ShellProfile.desktop:
      // Beside the executable on Windows; in the bundle's lib/ on Linux,
      // where the runner loaded it from.
      final windows = (os ?? Platform.operatingSystem) == 'windows';
      final dir = (windows ? p.windows : p.posix).dirname(exe);
      return windows
          ? p.windows.join(dir, 'dena_host.dll')
          : p.posix.join(dir, 'lib', 'libdena_host.so');
    case ShellProfile.handheld:
    case ShellProfile.none:
      return null;
  }
}

DynamicLibrary? _cached;
bool _tried = false;

/// The host library, or null where the shell has none (tests, a desktop
/// build without dena_host). Opening the file the runner already loaded
/// shares its state.
DynamicLibrary? openHostLibrary() {
  if (_tried) return _cached;
  _tried = true;
  try {
    final profile = shellProfile;
    if (profile == ShellProfile.handheld) {
      return _cached = DynamicLibrary.process();
    }
    final path = hostLibraryPath(profile);
    return _cached = path == null ? null : DynamicLibrary.open(path);
  } on ArgumentError {
    return null;
  }
}

int Function()? _texture;

/// The desktop runner's game texture id (desktop-shell.md), or null without
/// the desktop host library.
int? desktopGameTexture() {
  if (shellProfile != ShellProfile.desktop) return null;
  try {
    _texture ??= openHostLibrary()
        ?.lookupFunction<Int64 Function(), int Function()>(
          'dena_desktop_texture',
        );
  } on ArgumentError {
    return null;
  }
  final id = _texture?.call();
  return id == null || id < 0 ? null : id;
}

/// Tells the desktop host library where the storage root is (Bios,
/// Screenshots, cores, the latency log); before the first game. No-op
/// without it.
void configureDesktopHost(Directory root) {
  if (shellProfile != ShellProfile.desktop) return;
  final lib = openHostLibrary();
  if (lib == null) return;
  try {
    final setRoot = lib
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('dena_desktop_set_root');
    using((arena) => setRoot(root.path.toNativeUtf8(allocator: arena)));
  } on ArgumentError {
    // An older library: games use the defaults.
  }
}

void Function(int, int)? _outputSize;

/// Tells the desktop host library the game picture's size in physical
/// pixels, which shader stacks render at (shader-stacks.md, Platform); 0, 0
/// for the default. No-op without it.
void setDesktopOutputSize(int width, int height) {
  if (shellProfile != ShellProfile.desktop) return;
  try {
    _outputSize ??= openHostLibrary()
        ?.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>(
          'dena_desktop_set_output_size',
        );
  } on ArgumentError {
    return; // an older library: the default size
  }
  _outputSize?.call(width, height);
}
