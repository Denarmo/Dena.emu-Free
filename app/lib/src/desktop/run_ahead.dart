// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Input > Run-ahead (Windows and SteamOS): hides frames of the
// game's own input lag by running the core ahead with save states.
// Spec: docs/specs/run-ahead.md
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import '../shell/host_library.dart';
import '../shell/platform_features.dart';
import '../ui/brutal/brutal.dart';

/// How the host runs ahead (desktop.h, dena_desktop_set_run_ahead).
enum RunAheadMethod {
  /// Replays the last frames only when the input changes; real frames.
  preemptive(1, 'Preemptive', 'Replays frames when a button changes'),

  /// Runs ahead every frame and shows a predicted frame. Cores that hand
  /// out sound in blocks (GB/GBC, SNES) run preemptive instead.
  runAhead(2, 'Run-ahead', 'Every frame, more CPU (GB/GBC/SNES: Preemptive)');

  const RunAheadMethod(this.hostCode, this.label, this.description);

  final int hostCode;
  final String label;
  final String description;
}

/// Sends the choice to the host library.
typedef RunAheadSink = void Function(int mode, int frames);

/// The run-ahead choice, kept in `desktop_run_ahead.json` in the data
/// folder. Every change (and the load) goes to [sink].
class RunAheadSettings extends ChangeNotifier {
  RunAheadSettings({
    this.file,
    this.sink,
    int frames = defaultFrames,
    this._method = RunAheadMethod.preemptive,
  }) : _frames = frames.clamp(0, maxFrames) {
    _apply();
  }

  /// Reads [file]; a missing or damaged file gives the defaults.
  factory RunAheadSettings.load(File file, {RunAheadSink? sink}) {
    var frames = defaultFrames;
    var method = RunAheadMethod.preemptive;
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map) {
          if (j['frames'] case final int f) frames = f;
          method = RunAheadMethod.values.firstWhere(
            (m) => m.name == j['method'],
            orElse: () => RunAheadMethod.preemptive,
          );
        }
      }
    } on Object {
      // Defaults; the next change rewrites the file.
    }
    return RunAheadSettings(
      file: file,
      sink: sink,
      frames: frames,
      method: method,
    );
  }

  /// One frame is hidden by nearly every game (run-ahead.md, Defaults).
  static const defaultFrames = 1;
  static const maxFrames = 3;

  final File? file;
  final RunAheadSink? sink;
  int _frames;
  RunAheadMethod _method;

  /// Frames run ahead, 0 for off.
  int get frames => _frames;
  RunAheadMethod get method => _method;

  set frames(int value) {
    final f = value.clamp(0, maxFrames);
    if (f == _frames) return;
    _frames = f;
    _changed();
  }

  set method(RunAheadMethod value) {
    if (value == _method) return;
    _method = value;
    _changed();
  }

  void _apply() => sink?.call(_frames == 0 ? 0 : _method.hostCode, _frames);

  void _changed() {
    _apply();
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({'frames': _frames, 'method': _method.name}),
      );
    } on Object catch (e) {
      debugPrint('Run-ahead settings not saved: $e');
    }
  }
}

/// `1 FRAME · PREEMPTIVE`, or `OFF`.
String runAheadSummary(RunAheadSettings s) => s.frames == 0
    ? 'off'
    : '${s.frames} frame${s.frames == 1 ? '' : 's'} · ${s.method.label}';

/// dena_desktop_set_run_ahead of dena_host.dll / libdena_host.so; null off
/// the desktop or with a host library that predates run-ahead.
RunAheadSink? openRunAheadSink() {
  if (shellProfile != ShellProfile.desktop) return null;
  final lib = openHostLibrary();
  if (lib == null) return null;
  try {
    final set = lib
        .lookupFunction<Void Function(Int32, Int32), void Function(int, int)>(
          'dena_desktop_set_run_ahead',
        );
    return (mode, frames) => set(mode, frames);
  } on ArgumentError {
    return null;
  }
}

/// Gives Settings the run-ahead choice; absent off the desktop.
class RunAheadScope extends InheritedNotifier<RunAheadSettings> {
  const RunAheadScope({
    super.key,
    required RunAheadSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static RunAheadSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RunAheadScope>()?.notifier;
}

/// The `RUN-AHEAD ....... 1 FRAME · PREEMPTIVE >` row of the settings.
class RunAheadTile extends StatelessWidget {
  const RunAheadTile({super.key, required this.settings});

  final RunAheadSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => CfgRow(
      label: 'Run-ahead',
      value: runAheadSummary(settings),
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RunAheadPage(settings: settings),
        ),
      ),
    ),
  );
}

/// Frames (OFF 1 2 3) and the method, each choice explained.
class RunAheadPage extends StatelessWidget {
  const RunAheadPage({super.key, required this.settings});

  final RunAheadSettings settings;

  static const _frameChoices = [0, 1, 2, 3];

  @override
  Widget build(BuildContext context) {
    const methods = RunAheadMethod.values;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Shortcuts(
        shortcuts: arrowsMoveFocus,
        child: CfgPage(
          title: 'Run-ahead',
          path: const ['settings', 'input.cfg', 'run-ahead'],
          sections: [
            CfgTable(
              header: 'RUN_AHEAD.CFG',
              rows: [
                CfgRow(
                  label: 'Frames',
                  // The D-pad starts on the frame choices.
                  control: AutofocusFirst(
                    child: CfgSegment<int>(
                      values: _frameChoices,
                      selected: settings.frames,
                      labelOf: (f) => f == 0 ? 'Off' : '$f',
                      onChanged: (f) => settings.frames = f,
                    ),
                  ),
                ),
              ],
            ),
            BrutalTable(
              shrinkWrap: true,
              columns: const [
                BrutalColumn('', width: 44),
                BrutalColumn('Method', width: 128),
                BrutalColumn('How', flex: 1),
              ],
              rowCount: methods.length,
              selectedRow: methods.indexOf(settings.method),
              onRowPressed: (i) => settings.method = methods[i],
              cellBuilder: (context, row, column, lit) => Text(switch (column) {
                0 => methods[row] == settings.method ? '[x]' : '[ ]',
                1 => methods[row].label.toUpperCase(),
                _ => methods[row].description,
              }),
            ),
            const LogLine(
              '> Hides frames of the game\'s own input lag. Works on NES, '
              'SNES, GB/GBC/GBA, PICO-8 and PS1 (up to 2 frames); other '
              'systems play normally. If a game stutters or skips its first '
              'animation frame, use fewer frames.',
            ),
          ],
        ),
      ),
    );
  }
}
