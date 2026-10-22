// SPDX-License-Identifier: GPL-3.0-or-later
// Whether the device can go online. Spec: docs/specs/handheld-ui.md (Network)
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'wifi.dart';

/// Whether the device has Wi-Fi hardware: a wireless PHY in
/// `/sys/class/ieee80211`, or a network interface with a `wireless`
/// directory. [sys] is the sysfs root (tests pass a fake tree).
bool detectWifiHardware({String sys = '/sys'}) {
  try {
    final phys = Directory(p.join(sys, 'class', 'ieee80211'));
    if (phys.existsSync() && phys.listSync().isNotEmpty) return true;
    final net = Directory(p.join(sys, 'class', 'net'));
    if (!net.existsSync()) return false;
    for (final iface in net.listSync()) {
      if (Directory(p.join(iface.path, 'wireless')).existsSync()) return true;
    }
  } on FileSystemException {
    // Unreadable sysfs: no Wi-Fi as far as the app can tell.
  }
  return false;
}

/// Whether this device can go online. Phones always can; a handheld only
/// with Wi-Fi hardware, probed once at startup ([detectWifiHardware]).
bool detectNetwork({required bool handheld, String sys = '/sys'}) =>
    !handheld || detectWifiHardware(sys: sys);

/// Tells screens whether the device can go online. Without it (no Wi-Fi
/// hardware on a handheld) the online features stay out of the UI: Google
/// Drive, RomM, the web file manager, Dena Explore and the BBS browser,
/// RetroAchievements and the link cable.
class NetworkScope extends InheritedWidget {
  const NetworkScope({
    super.key,
    required this.online,
    this.wifi,
    required super.child,
  });

  final bool online;

  /// The handheld's Wi-Fi settings (Settings > Wi-Fi); none on phones.
  final WifiControl? wifi;

  static WifiControl? wifiOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NetworkScope>()?.wifi;

  /// True when there is no scope (phones, tests).
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NetworkScope>()?.online ??
      true;

  /// Without listening (callbacks).
  static bool read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NetworkScope>()?.online ?? true;

  @override
  bool updateShouldNotify(NetworkScope old) =>
      online != old.online || wifi != old.wifi;
}
