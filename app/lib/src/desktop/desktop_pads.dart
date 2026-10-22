// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop host library's gamepads for the UI: how many there are, and
// their presses while no game plays (desktop.h, dena_desktop_set_ui_input).
// Spec: docs/specs/controller-mode.md
import 'dart:ffi';

import '../shell/host_library.dart';
import '../shell/platform_features.dart';

/// Gamepads as the launch rule and controller mode see them.
abstract interface class DesktopPads {
  /// Gamepads connected now.
  int count();

  /// The host family of the pad used last (or connected first), -1 without
  /// pads (desktop.h, DENA_DESKTOP_FAMILY_*).
  int family();

  /// Calls [onAction] for each UI action (a RetroPad id or 16 for Guide)
  /// while no game is playing, until [close].
  void listen(void Function(int action, bool down, int family) onAction);

  void close();
}

typedef _UiNative = Void Function(Int32, Int32, Int32);

/// The pads of dena_host.dll / libdena_host.so.
class FfiDesktopPads implements DesktopPads {
  FfiDesktopPads._(this._count, this._family, this._setUi);

  /// Null off the desktop or without the host library (or an older one).
  static FfiDesktopPads? open() {
    if (shellProfile != ShellProfile.desktop) return null;
    final lib = openHostLibrary();
    if (lib == null) return null;
    try {
      return FfiDesktopPads._(
        lib.lookupFunction<Int32 Function(), int Function()>(
          'dena_desktop_gamepads',
        ),
        lib.lookupFunction<Int32 Function(), int Function()>(
          'dena_desktop_gamepad_family',
        ),
        lib.lookupFunction<
          Void Function(Pointer<NativeFunction<_UiNative>>),
          void Function(Pointer<NativeFunction<_UiNative>>)
        >('dena_desktop_set_ui_input'),
      );
    } on ArgumentError {
      return null;
    }
  }

  final int Function() _count;
  final int Function() _family;
  final void Function(Pointer<NativeFunction<_UiNative>>) _setUi;
  NativeCallable<_UiNative>? _callable;

  @override
  int count() => _count();

  @override
  int family() => _family();

  @override
  void listen(void Function(int action, bool down, int family) onAction) {
    close();
    // SDL's thread calls it; a listener hands each call to this isolate.
    final callable = NativeCallable<_UiNative>.listener(
      (int action, int down, int family) => onAction(action, down != 0, family),
    );
    _callable = callable;
    _setUi(callable.nativeFunction);
  }

  @override
  void close() {
    final callable = _callable;
    if (callable == null) return;
    _setUi(nullptr);
    callable.close();
    _callable = null;
  }
}
