// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Display > Fullscreen at launch (Windows and SteamOS).
// Spec: docs/specs/controller-mode.md, docs/specs/brutalist-ui.md (4.6, 4.12)
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import '../ui/brutal/brutal.dart';
import 'launch_rule.dart';

/// The desktop's display choices, kept in `desktop_display.json` in the
/// data folder.
class DesktopDisplaySettings extends ChangeNotifier {
  DesktopDisplaySettings({
    this.file,
    this._fullscreen = FullscreenAtLaunch.auto,
  });

  /// Reads [file]; a missing or damaged file gives the defaults.
  factory DesktopDisplaySettings.load(File file) {
    var fullscreen = FullscreenAtLaunch.auto;
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map) {
          fullscreen = FullscreenAtLaunch.values.firstWhere(
            (f) => f.name == j['fullscreenAtLaunch'],
            orElse: () => FullscreenAtLaunch.auto,
          );
        }
      }
    } on Object {
      // Defaults; the next change rewrites the file.
    }
    return DesktopDisplaySettings(file: file, fullscreen: fullscreen);
  }

  final File? file;
  FullscreenAtLaunch _fullscreen;

  FullscreenAtLaunch get fullscreenAtLaunch => _fullscreen;

  set fullscreenAtLaunch(FullscreenAtLaunch value) {
    if (value == _fullscreen) return;
    _fullscreen = value;
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'fullscreenAtLaunch': value.name}));
    } on Object catch (e) {
      debugPrint('Display settings not saved: $e');
    }
  }
}

/// Gives Settings the desktop's display settings; absent off the desktop.
class DesktopDisplayScope extends InheritedNotifier<DesktopDisplaySettings> {
  const DesktopDisplayScope({
    super.key,
    required DesktopDisplaySettings settings,
    required super.child,
  }) : super(notifier: settings);

  static DesktopDisplaySettings? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DesktopDisplayScope>()
      ?.notifier;
}

/// The `FULLSCREEN AT LAUNCH [AUTO] ALWAYS NEVER` row of the settings
/// (brutalist-ui.md 4.12).
class FullscreenAtLaunchTile extends StatelessWidget {
  const FullscreenAtLaunchTile({super.key, required this.settings});

  final DesktopDisplaySettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => CfgRow(
      label: 'Fullscreen at launch',
      control: CfgSegment<FullscreenAtLaunch>(
        values: FullscreenAtLaunch.values,
        selected: settings.fullscreenAtLaunch,
        labelOf: (f) => f.label,
        onChanged: (f) => settings.fullscreenAtLaunch = f,
      ),
    ),
  );
}

/// The same choice as a picker page with each choice explained.
class FullscreenAtLaunchPage extends StatelessWidget {
  const FullscreenAtLaunchPage({super.key, required this.settings});

  final DesktopDisplaySettings settings;

  @override
  Widget build(BuildContext context) {
    const choices = FullscreenAtLaunch.values;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Shortcuts(
        shortcuts: arrowsMoveFocus,
        child: CfgPage(
          title: 'Fullscreen at launch',
          path: const ['settings', 'input.cfg', 'fullscreen'],
          sections: [
            BrutalTable(
              shrinkWrap: true,
              columns: const [
                BrutalColumn('', width: 44),
                BrutalColumn('Start', width: 96),
                BrutalColumn('When', flex: 1),
              ],
              rowCount: choices.length,
              selectedRow: choices.indexOf(settings.fullscreenAtLaunch),
              // The D-pad starts on the current choice.
              autofocusRow: choices.indexOf(settings.fullscreenAtLaunch),
              onRowPressed: (i) => settings.fullscreenAtLaunch = choices[i],
              cellBuilder: (context, row, column, lit) => Text(switch (column) {
                0 =>
                  choices[row] == settings.fullscreenAtLaunch ? '[x]' : '[ ]',
                1 => choices[row].label.toUpperCase(),
                _ => choices[row].description,
              }),
            ),
            const LogLine(
              '> F11 or Alt+Enter switches between fullscreen and a window '
              'at any time.',
            ),
          ],
        ),
      ),
    );
  }
}
