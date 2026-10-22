// SPDX-License-Identifier: GPL-3.0-or-later
// The launcher's side of the power daemon protocol (handhelds only).
// Spec: docs/specs/power-daemon.md (Launcher protocol)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'device_settings.dart';
import 'usb_storage.dart';

/// A line-based connection to dena-powerd.
abstract interface class PowerChannel {
  Stream<String> get lines;
  void send(String line);
}

/// [PowerChannel] over the daemon's Unix socket.
class SocketPowerChannel implements PowerChannel {
  SocketPowerChannel._(this._socket)
    : lines = _socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();

  final Socket _socket;

  @override
  final Stream<String> lines;

  /// Null when the daemon isn't running (or off a handheld).
  static Future<SocketPowerChannel?> connect([
    String path = '/tmp/dena-power.sock',
  ]) async {
    if (!Platform.isLinux) return null;
    try {
      final s = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      return SocketPowerChannel._(s);
    } on SocketException {
      return null;
    }
  }

  @override
  void send(String line) => _socket.write('$line\n');
}

/// Reacts to the daemon: saves before sleep or power off, reopens the pause
/// menu after waking, shows the battery warning, and reports activity.
class PowerLink {
  PowerLink(this._channel, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _sub = _channel.lines.listen(_onLine);
  }

  final PowerChannel _channel;
  final DateTime Function() _clock;
  late final StreamSubscription<String> _sub;
  DateTime? _lastActivity;

  /// Pauses the running game and flushes its saves; set by the session while
  /// a game runs. Without one there is nothing to save.
  Future<void> Function()? onSave;

  /// The device woke up: the session shows its pause menu.
  void Function()? onResumed;

  /// Saving before sleep or power off failed (logged by the launcher).
  void Function(Object error, StackTrace stack)? onSaveError;

  /// Battery is low: show a warning.
  void Function()? onBatteryLow;

  /// Minimum gap between activity reports (the idle timer is minutes long).
  static const activityGap = Duration(seconds: 10);

  Future<void> _onLine(String line) async {
    switch (line.trim()) {
      case 'save':
        try {
          await onSave?.call();
        } catch (e, st) {
          // Answer even if saving failed: the daemon would only time out.
          onSaveError?.call(e, st);
        }
        _channel.send('saved');
      case 'resumed':
        onResumed?.call();
      case 'battery-low':
        onBatteryLow?.call();
    }
  }

  /// Call on any user input; sends at most one report per [activityGap].
  void activity() {
    final now = _clock();
    final last = _lastActivity;
    if (last != null && now.difference(last) < activityGap) return;
    _lastActivity = now;
    _channel.send('activity');
  }

  /// Backlight level 0-100 from Settings.
  void brightness(int percent) =>
      _channel.send('brightness ${percent.clamp(1, 100)}');

  Future<void> close() => _sub.cancel();
}

/// Gives screens the daemon link; null off handhelds.
class PowerScope extends InheritedWidget {
  const PowerScope({
    super.key,
    required this.link,
    this.device,
    this.usb,
    required super.child,
  });

  final PowerLink? link;

  /// The card's device settings (brightness); null off a card.
  final DeviceSettings? device;

  /// USB storage mode; null off the single-card system.
  final UsbStorage? usb;

  static PowerLink? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PowerScope>()?.link;

  static DeviceSettings? deviceOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PowerScope>()?.device;

  static UsbStorage? usbOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PowerScope>()?.usb;

  @override
  bool updateShouldNotify(PowerScope old) =>
      link != old.link || device != old.device || usb != old.usb;
}
