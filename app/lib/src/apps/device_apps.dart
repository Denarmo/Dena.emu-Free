// SPDX-License-Identifier: GPL-3.0-or-later
// Installed launchable apps and the home-launcher role (Android only).
// Spec: docs/specs/apps-tab.md
import 'dart:io';

import 'package:flutter/services.dart';

/// A launchable app on the device.
class DeviceApp {
  const DeviceApp({required this.package, required this.label, this.icon});

  final String package;
  final String label;

  /// PNG bytes, or null when the icon could not be read.
  final Uint8List? icon;
}

/// Lists and launches installed apps; asks to become the home launcher.
abstract class DeviceApps {
  Future<List<DeviceApp>> list();
  Future<void> launch(String package);

  /// True when Dena.emu is the current home app.
  Future<bool> isHome();

  /// Asks the system to make Dena.emu the home app (RoleManager on 10+,
  /// the Home settings screen otherwise).
  Future<void> requestHome();

  /// The platform implementation, or null where there is none.
  static DeviceApps? get platform =>
      Platform.isAndroid ? const ChannelDeviceApps() : null;
}

/// Lifecycle calls only, so a method channel is fine (not the hot path).
class ChannelDeviceApps implements DeviceApps {
  const ChannelDeviceApps();

  static const _channel = MethodChannel('app.dena/apps');

  @override
  Future<List<DeviceApp>> list() async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('list');
    final apps = [
      for (final m in raw ?? const <Map<Object?, Object?>>[])
        DeviceApp(
          package: m['package']! as String,
          label: m['label']! as String,
          icon: m['icon'] as Uint8List?,
        ),
    ];
    apps.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return apps;
  }

  @override
  Future<void> launch(String package) =>
      _channel.invokeMethod<void>('launch', package);

  @override
  Future<bool> isHome() async =>
      await _channel.invokeMethod<bool>('isHome') ?? false;

  @override
  Future<void> requestHome() => _channel.invokeMethod<void>('requestHome');
}
