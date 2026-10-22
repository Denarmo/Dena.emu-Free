// SPDX-License-Identifier: GPL-3.0-or-later
// SteamOS Gaming Mode: gamescope detection and Steam's on-screen keyboard.
// Spec: docs/specs/deck-presets.md (Gaming Mode)
import 'dart:io';

import '../ui/onscreen_keyboard.dart' show HandheldTextEntry;

/// Whether the app runs under gamescope (SteamOS Gaming Mode, or a gamescope
/// session on another distro).
bool detectGamescope({Map<String, String>? env, String? os}) {
  if ((os ?? Platform.operatingSystem) != 'linux') return false;
  final vars = env ?? Platform.environment;
  return (vars['GAMESCOPE_WAYLAND_DISPLAY'] ?? '').isNotEmpty ||
      (vars['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase() == 'gamescope';
}

/// Runs a command; the exit code, or -1 when it could not start.
typedef CommandRunner = Future<int> Function(String exe, List<String> args);

Future<int> _runCommand(String exe, List<String> args) async {
  try {
    return (await Process.run(exe, args)).exitCode;
  } on Object {
    return -1;
  }
}

/// Steam's keyboard for text fields in Gaming Mode: A on a text field asks
/// Steam to show it (`steam://open/keyboard`, through the OpenURI portal in
/// the Flatpak) and it types into the focused field. When Steam does not
/// answer, the app's own on-screen keyboard opens as before.
class SteamKeyboard {
  SteamKeyboard({CommandRunner? run}) : _run = run ?? _runCommand;

  final CommandRunner _run;

  /// Asks Steam for its keyboard; false when that failed.
  Future<bool> open() async =>
      await _run('xdg-open', const ['steam://open/keyboard']) == 0;

  /// Makes A on a text field use Steam's keyboard (on under gamescope).
  void install() => HandheldTextEntry.external = (_) => open();

  /// Back to the app's own keyboard.
  static void uninstall() => HandheldTextEntry.external = null;
}
