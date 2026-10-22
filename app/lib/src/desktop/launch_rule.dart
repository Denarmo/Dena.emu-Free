// SPDX-License-Identifier: GPL-3.0-or-later
// The controller-at-launch rule: a gamepad at start means fullscreen and
// controller mode. Spec: docs/specs/controller-mode.md
import 'dart:async';
import 'dart:io';

/// Settings > Display > Fullscreen at launch.
enum FullscreenAtLaunch {
  /// Fullscreen when a gamepad is there at launch (the default).
  auto,
  always,
  never;

  String get label => switch (this) {
    auto => 'Auto',
    always => 'Always',
    never => 'Never',
  };

  String get description => switch (this) {
    auto => 'Fullscreen when a controller is connected at launch',
    always => 'Always start fullscreen',
    never => 'Always start in a window',
  };
}

/// What the app starts as.
typedef LaunchMode = ({bool fullscreen, bool controllerMode});

/// The rule: any gamepad (the Deck's own controls count) means controller
/// mode; Auto then goes fullscreen with it, Always and Never override only
/// the window. Under gamescope (Gaming Mode) it is always fullscreen
/// controller mode (deck-presets.md).
LaunchMode decideLaunch({
  required FullscreenAtLaunch setting,
  required int gamepads,
  bool steamDeck = false,
  bool gamescope = false,
}) {
  if (gamescope) return (fullscreen: true, controllerMode: true);
  final pad = gamepads > 0 || steamDeck;
  return (
    fullscreen: switch (setting) {
      FullscreenAtLaunch.auto => pad,
      FullscreenAtLaunch.always => true,
      FullscreenAtLaunch.never => false,
    },
    controllerMode: pad,
  );
}

/// How long the launch waits for slow USB and Bluetooth pads to show up.
const gamepadWait = Duration(milliseconds: 500);

/// Polls [count] until a gamepad is there or [timeout] passes; returns the
/// last count. A pad already enumerated returns at once.
Future<int> waitForGamepads(
  int Function() count, {
  Duration timeout = gamepadWait,
  Duration every = const Duration(milliseconds: 20),
}) async {
  final watch = Stopwatch()..start();
  var n = count();
  while (n == 0 && watch.elapsed < timeout) {
    await Future<void>.delayed(every);
    n = count();
  }
  return n;
}

/// Whether this is a Steam Deck: Steam sets `SteamDeck=1` there, and the
/// board vendor is Valve (Jupiter LCD, Galileo OLED).
bool detectSteamDeck({
  Map<String, String>? env,
  String? os,
  String Function(String path)? readFile,
}) {
  if ((os ?? Platform.operatingSystem) != 'linux') return false;
  final vars = env ?? Platform.environment;
  if (vars['SteamDeck'] == '1') return true;
  final read = readFile ?? (String p) => File(p).readAsStringSync();
  try {
    final vendor = read('/sys/class/dmi/id/board_vendor').trim();
    final board = read('/sys/class/dmi/id/board_name').trim();
    return vendor == 'Valve' && (board == 'Jupiter' || board == 'Galileo');
  } on Object {
    return false;
  }
}
