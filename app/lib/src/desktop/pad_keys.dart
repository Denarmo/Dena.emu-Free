// SPDX-License-Identifier: GPL-3.0-or-later
// Gamepad buttons as Flutter key events, so the desktop UI navigates with
// the same keys as the handheld's embedder (embedder_core.h): D-pad =
// arrows, A/B/X/Y/L1/R1/... = game buttons, Guide = gameButtonMode.
// Spec: docs/specs/controller-mode.md
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// The Flutter key for a host UI action (a RetroPad joypad id 0-15, or 16
/// for Guide), or null for none.
LogicalKeyboardKey? padActionKey(int action) => switch (action) {
  0 => LogicalKeyboardKey.gameButtonB,
  1 => LogicalKeyboardKey.gameButtonY,
  2 => LogicalKeyboardKey.gameButtonSelect,
  3 => LogicalKeyboardKey.gameButtonStart,
  4 => LogicalKeyboardKey.arrowUp,
  5 => LogicalKeyboardKey.arrowDown,
  6 => LogicalKeyboardKey.arrowLeft,
  7 => LogicalKeyboardKey.arrowRight,
  8 => LogicalKeyboardKey.gameButtonA,
  9 => LogicalKeyboardKey.gameButtonX,
  10 => LogicalKeyboardKey.gameButtonLeft1,
  11 => LogicalKeyboardKey.gameButtonRight1,
  12 => LogicalKeyboardKey.gameButtonLeft2,
  13 => LogicalKeyboardKey.gameButtonRight2,
  14 => LogicalKeyboardKey.gameButtonThumbLeft,
  15 => LogicalKeyboardKey.gameButtonThumbRight,
  16 => LogicalKeyboardKey.gameButtonMode,
  _ => null,
};

/// The physical key the handheld's embedder pairs with [logical]: USB HID
/// usages for arrows, 0x0005ff00 + the low byte for game buttons.
PhysicalKeyboardKey padPhysicalKey(LogicalKeyboardKey logical) =>
    switch (logical) {
      LogicalKeyboardKey.arrowUp => PhysicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown => PhysicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft => PhysicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight => PhysicalKeyboardKey.arrowRight,
      _ => PhysicalKeyboardKey(0x0005ff00 + (logical.keyId & 0xff)),
    };

bool _isDirection(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.arrowUp ||
    k == LogicalKeyboardKey.arrowDown ||
    k == LogicalKeyboardKey.arrowLeft ||
    k == LogicalKeyboardKey.arrowRight;

/// Sends one key event into the framework.
typedef KeyDataSink = void Function(ui.KeyData data);

/// Feeds the framework the way a platform embedder does. The events are
/// marked synthesized, so they are dispatched at once and never wait for a
/// raw key message that will not come.
void dispatchToFramework(ui.KeyData data) {
  // The engine's own entry point for KeyData; there is no newer public one
  // for injecting keys (it is how the handheld embedder's events arrive).
  // ignore: deprecated_member_use
  ServicesBinding.instance.keyEventManager.handleKeyData(data);
}

/// Turns pad presses into key downs, ups and repeats: held D-pad directions
/// (and the stick) repeat after 400 ms, then every 80 ms, as on the
/// handheld (handheld-ui.md, Focus).
class PadKeySynth {
  PadKeySynth({KeyDataSink? sink, Duration Function()? clock})
    : _sink = sink ?? dispatchToFramework,
      _clock = clock ?? _uptime;

  static const repeatDelay = Duration(milliseconds: 400);
  static const repeatEvery = Duration(milliseconds: 80);

  final KeyDataSink _sink;
  final Duration Function() _clock;
  final _held = <LogicalKeyboardKey>{};
  final _repeats = <LogicalKeyboardKey, Timer>{};

  static final _stopwatch = Stopwatch()..start();
  static Duration _uptime() => _stopwatch.elapsed;

  /// A host UI action went [down] or up.
  void action(int action, bool down) {
    final key = padActionKey(action);
    if (key == null) return;
    if (down) {
      // A release the menu never saw (it went to the game): let go first,
      // so the framework's pressed-key state stays consistent.
      if (_held.contains(key)) _up(key);
      _held.add(key);
      _send(ui.KeyEventType.down, key);
      if (_isDirection(key)) {
        _repeats[key] = Timer(repeatDelay, () {
          if (!_held.contains(key)) return;
          _send(ui.KeyEventType.repeat, key);
          _repeats[key] = Timer.periodic(repeatEvery, (_) {
            if (_held.contains(key)) _send(ui.KeyEventType.repeat, key);
          });
        });
      }
    } else if (_held.contains(key)) {
      _up(key);
    }
    // A release without a press (it started in the game) is dropped.
  }

  /// Lets go of everything (the window lost the pad, a game started).
  void releaseAll() {
    for (final key in _held.toList()) {
      _up(key);
    }
  }

  void dispose() {
    for (final t in _repeats.values) {
      t.cancel();
    }
    _repeats.clear();
    _held.clear();
  }

  void _up(LogicalKeyboardKey key) {
    _repeats.remove(key)?.cancel();
    _held.remove(key);
    _send(ui.KeyEventType.up, key);
  }

  void _send(ui.KeyEventType type, LogicalKeyboardKey key) => _sink(
    ui.KeyData(
      timeStamp: _clock(),
      type: type,
      physical: padPhysicalKey(key).usbHidUsage,
      logical: key.keyId,
      character: null,
      synthesized: true,
    ),
  );
}
