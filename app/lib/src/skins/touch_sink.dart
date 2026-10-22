// SPDX-License-Identifier: GPL-3.0-or-later
// Sends touch-control masks to the native runner over dart:ffi.
// Spec: docs/specs/skins.md (Hot path)
import 'dart:ffi';

import '../shell/host_library.dart';
import '../shell/platform_features.dart';

/// Where touch masks go. The app uses [FfiTouchSink]; tests use a fake.
abstract interface class TouchSink {
  void setButtons(int mask);

  /// The libretro pointer (ds.md): x/y from -0x7fff to 0x7fff over the frame.
  void setPointer(int x, int y, bool pressed);

  /// A touch stick (n64.md): stick 0 left / 1 right, -0x7fff..0x7fff.
  void setAnalog(int stick, int x, int y);

  /// Turbo buttons (turbo.md): libretro joypad bits that toggle every
  /// [halfFrames] frames while held, for touch and gamepads. 0 = off.
  void setTurbo(int mask, int halfFrames);
}

/// Calls `dena_touch_buttons` in `libdena_android.so` directly (no method
/// channel on the input hot path, CLAUDE.md §3).
class FfiTouchSink implements TouchSink {
  FfiTouchSink._(this._fn, this._pointer, this._analog, this._turbo);

  final void Function(int) _fn;
  final void Function(int, int, int) _pointer;
  final void Function(int, int, int) _analog;
  final void Function(int, int) _turbo;

  /// Null where the native library is not available (desktop, tests).
  static FfiTouchSink? open() {
    if (shellProfile == ShellProfile.handheld) return _openLauncher();
    try {
      final lib = openHostLibrary();
      if (lib == null) return null;
      final fn = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'dena_touch_buttons',
      );
      final pointer = lib
          .lookupFunction<
            Void Function(Int32, Int32, Int32),
            void Function(int, int, int)
          >('dena_touch_pointer');
      final analog = lib
          .lookupFunction<
            Void Function(Int32, Int32, Int32),
            void Function(int, int, int)
          >('dena_touch_analog');
      final turbo = lib
          .lookupFunction<Void Function(Int32, Int32), void Function(int, int)>(
            'dena_set_turbo',
          );
      return FfiTouchSink._(fn, pointer, analog, turbo);
    } on ArgumentError {
      return null;
    }
  }

  /// The handheld launcher has no touch screen: only turbo, which it exports
  /// from its own process (handheld-session.md). Null outside the launcher.
  static FfiTouchSink? _openLauncher() {
    try {
      final turbo = DynamicLibrary.process()
          .lookupFunction<Void Function(Int32, Int32), void Function(int, int)>(
            'dena_set_turbo',
          );
      return FfiTouchSink._(_noTouch, _noPointer, _noPointer, turbo);
    } on ArgumentError {
      return null;
    }
  }

  static void _noTouch(int _) {}
  static void _noPointer(int _, int _, int _) {}

  @override
  void setButtons(int mask) => _fn(mask);

  @override
  void setPointer(int x, int y, bool pressed) =>
      _pointer(x, y, pressed ? 1 : 0);

  @override
  void setAnalog(int stick, int x, int y) => _analog(stick, x, y);

  @override
  void setTurbo(int mask, int halfFrames) => _turbo(mask, halfFrames);
}
