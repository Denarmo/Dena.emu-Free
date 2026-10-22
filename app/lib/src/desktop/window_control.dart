// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop runners' "dena/window" channel: borderless fullscreen and the
// remembered window position. F11 and Alt+Enter toggle fullscreen in the
// runners themselves, so they work during a game too.
// Spec: docs/specs/controller-mode.md
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowControl {
  const WindowControl([this.channel = const MethodChannel('dena/window')]);

  final MethodChannel channel;

  /// Borderless fullscreen on the monitor the window is on, or back to the
  /// window it was.
  Future<void> setFullscreen(bool on) => _call('setFullscreen', on);

  Future<bool> isFullscreen() async =>
      await _call<bool>('isFullscreen') ?? false;

  /// Puts the window where [path] says it was last (if that monitor is still
  /// there) and saves it there when the window closes.
  Future<void> restorePlacement(String path) => _call('restorePlacement', path);

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null; // a runner without the channel: stays as it is
    } on PlatformException catch (e) {
      debugPrint('dena/window $method: ${e.message}');
      return null;
    }
  }
}
