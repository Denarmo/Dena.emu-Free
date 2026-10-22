// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Video > Presets (Windows and SteamOS, Steam Deck first): per
// system Battery / Balanced / Performance, each picking the internal
// resolution, run-ahead, a refresh rate that divides the frame rate evenly
// and a suggested TDP. Spec: docs/specs/deck-presets.md
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../shaders/shader_store.dart' show upscaleFactors;
import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import '../ui/brutal/brutal.dart';
import 'run_ahead.dart';

/// A system's preset; [off] keeps the user's own RES and run-ahead.
enum DeckPreset {
  off,
  battery,
  balanced,
  performance;

  /// The next one when A steps a system's row.
  DeckPreset get next => values[(index + 1) % values.length];
}

/// Which Steam Deck this is, for its panel's refresh range.
enum DeckModel {
  /// Not a Steam Deck.
  none(null, null, ''),

  /// Steam Deck LCD (board `Jupiter`): 40-60 Hz.
  lcd(40, 60, 'Steam Deck LCD'),

  /// Steam Deck OLED (board `Galileo`): 45-90 Hz.
  oled(45, 90, 'Steam Deck OLED');

  const DeckModel(this.minHz, this.maxHz, this.label);

  final int? minHz;
  final int? maxHz;
  final String label;
}

/// The Deck model from the board name (Valve `Jupiter` / `Galileo`); Steam's
/// `SteamDeck=1` alone counts as an LCD Deck.
DeckModel detectDeckModel({
  Map<String, String>? env,
  String? os,
  String Function(String path)? readFile,
}) {
  if ((os ?? Platform.operatingSystem) != 'linux') return DeckModel.none;
  final read = readFile ?? (String p) => File(p).readAsStringSync();
  try {
    if (read('/sys/class/dmi/id/board_vendor').trim() == 'Valve') {
      switch (read('/sys/class/dmi/id/board_name').trim()) {
        case 'Jupiter':
          return DeckModel.lcd;
        case 'Galileo':
          return DeckModel.oled;
      }
    }
  } on Object {
    // No DMI (a container, a sandbox without /sys): go by Steam's variable.
  }
  return (env ?? Platform.environment)['SteamDeck'] == '1'
      ? DeckModel.lcd
      : DeckModel.none;
}

/// Systems listed on the page, in the library's order.
const presetSystems = [
  'nes',
  'snes',
  'gb',
  'gbc',
  'gba',
  'n64',
  'nds',
  'psx',
  'psp',
  'saturn',
  'dreamcast',
  'gamecube',
  'wii',
  'ps2',
  'pico8',
];

/// Short names for the table.
String presetSystemLabel(String system) =>
    system == 'pico8' ? 'PICO-8' : system.toUpperCase();

/// Systems the host runs ahead (run-ahead.md, Defaults) and their limit.
const _runAheadMax = {
  'nes': 3,
  'snes': 3,
  'gb': 3,
  'gbc': 3,
  'gba': 3,
  'pico8': 3,
  'psx': 2,
};

/// Native picture height of the systems with a resolution choice (DS: both
/// screens stacked).
const _nativeHeight = {
  'n64': 240,
  'psx': 240,
  'psp': 272,
  'nds': 384,
  'dreamcast': 480,
  'gamecube': 528,
  'wii': 528,
  'ps2': 448,
};

/// Suggested TDP limit in watts on a Steam Deck: (battery, balanced,
/// performance). Starting points to check on the hardware.
const deckTdp = {
  'nes': (3, 4, 5),
  'gb': (3, 4, 5),
  'gbc': (3, 4, 5),
  'pico8': (3, 4, 5),
  'snes': (4, 5, 6),
  'gba': (4, 5, 6),
  'psx': (5, 7, 9),
  'nds': (5, 7, 10),
  'n64': (6, 9, 12),
  'psp': (7, 10, 13),
  'saturn': (6, 8, 10),
  'dreamcast': (7, 10, 13),
  'gamecube': (8, 11, 15),
  'wii': (8, 11, 15),
  'ps2': (9, 12, 15),
};
const _tdpOther = (5, 8, 12);

/// Frames a second the systems put out (PAL games: 50).
const contentFps = 60;

/// The refresh in [minHz]..[maxHz] that is a whole multiple of [fps]: the
/// lowest, or the highest with [high]; null when none is.
int? evenRefresh(int fps, int minHz, int maxHz, {bool high = false}) {
  int? best;
  for (var hz = fps; hz <= maxHz; hz += fps) {
    if (hz < minHz) continue;
    if (best == null || high) best = hz;
  }
  return best;
}

/// Whether a display at [hz] shows every frame of [fps] for the same time.
bool dividesEvenly(double hz, {int fps = contentFps}) {
  final k = hz / fps;
  return k > 0.98 && (k - k.roundToDouble()).abs() < 0.02;
}

/// What a preset picks for one system.
@immutable
class PresetPlan {
  const PresetPlan({
    required this.upscale,
    required this.runAhead,
    required this.refreshHz,
    required this.tdpWatts,
  });

  /// Internal resolution factor, 0 for Auto (native).
  final int upscale;

  /// Frames run ahead; null where the system does not run ahead.
  final int? runAhead;

  /// Suggested refresh; null off a Steam Deck.
  final int? refreshHz;

  /// Suggested TDP limit; null off a Steam Deck.
  final int? tdpWatts;

  @override
  bool operator ==(Object other) =>
      other is PresetPlan &&
      other.upscale == upscale &&
      other.runAhead == runAhead &&
      other.refreshHz == refreshHz &&
      other.tdpWatts == tdpWatts;

  @override
  int get hashCode => Object.hash(upscale, runAhead, refreshHz, tdpWatts);

  @override
  String toString() =>
      'PresetPlan(${upscale}x, ra $runAhead, $refreshHz Hz, $tdpWatts W)';
}

/// The plan of [preset] for [system] on a screen [screenHeight] pixels
/// high; null for [DeckPreset.off].
PresetPlan? planPreset(
  String system,
  DeckPreset preset, {
  required DeckModel model,
  required double screenHeight,
  bool desktop = true,
}) {
  if (preset == DeckPreset.off) return null;
  final factors = upscaleFactors(system, desktop: desktop);
  final native = _nativeHeight[system];
  var upscale = 0;
  if (native != null && factors.isNotEmpty) {
    final fits = [
      for (final f in factors)
        if (native * f <= screenHeight) f,
    ];
    final fills = [
      for (final f in factors)
        if (native * f >= screenHeight) f,
    ];
    upscale = switch (preset) {
      DeckPreset.balanced => fits.isEmpty ? 0 : fits.last,
      DeckPreset.performance => fills.isEmpty ? factors.last : fills.first,
      _ => 0,
    };
  }
  final maxAhead = _runAheadMax[system];
  final ahead = maxAhead == null
      ? null
      : switch (preset) {
          DeckPreset.battery => 0,
          DeckPreset.balanced => 1,
          _ => 2,
        }.clamp(0, maxAhead);
  final deck = model != DeckModel.none;
  final tdp = deckTdp[system] ?? _tdpOther;
  return PresetPlan(
    upscale: upscale,
    runAhead: ahead,
    refreshHz: deck
        ? evenRefresh(
            contentFps,
            model.minHz!,
            model.maxHz!,
            high: preset == DeckPreset.performance,
          )
        : null,
    tdpWatts: deck
        ? switch (preset) {
            DeckPreset.battery => tdp.$1,
            DeckPreset.balanced => tdp.$2,
            _ => tdp.$3,
          }
        : null,
  );
}

/// The preset per system, kept in `desktop_presets.json` in the data folder.
class DeckPresetSettings extends ChangeNotifier {
  DeckPresetSettings({
    this.file,
    this.model = DeckModel.none,
    Map<String, DeckPreset>? systems,
  }) : _systems = {...?systems};

  /// Reads [file]; a missing or damaged file gives the defaults.
  factory DeckPresetSettings.load(
    File file, {
    DeckModel model = DeckModel.none,
  }) {
    final systems = <String, DeckPreset>{};
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map && j['systems'] is Map) {
          for (final e in (j['systems'] as Map).entries) {
            final p = DeckPreset.values.where((v) => v.name == e.value);
            if (p.isNotEmpty) systems['${e.key}'] = p.first;
          }
        }
      }
    } on Object {
      systems.clear(); // Defaults; the next change rewrites the file.
    }
    return DeckPresetSettings(file: file, model: model, systems: systems);
  }

  final File? file;

  /// The Deck the app runs on, [DeckModel.none] elsewhere.
  final DeckModel model;
  final Map<String, DeckPreset> _systems;

  /// Balanced on a Steam Deck; off elsewhere, so a PC keeps its settings.
  DeckPreset get defaultPreset =>
      model == DeckModel.none ? DeckPreset.off : DeckPreset.balanced;

  DeckPreset presetOf(String system) => _systems[system] ?? defaultPreset;

  /// The one preset every system has, or null when they differ.
  DeckPreset? get common {
    final all = {for (final s in presetSystems) presetOf(s)};
    return all.length == 1 ? all.first : null;
  }

  void setPreset(String system, DeckPreset preset) {
    if (presetOf(system) == preset && _systems.containsKey(system)) return;
    _systems[system] = preset;
    _changed();
  }

  void setAll(DeckPreset preset) {
    for (final s in presetSystems) {
      _systems[s] = preset;
    }
    _changed();
  }

  /// What [system]'s preset picks on a screen [screenHeight] pixels high;
  /// null when it is off.
  PresetPlan? planFor(String system, {required double screenHeight}) =>
      planPreset(
        system,
        presetOf(system),
        model: model,
        screenHeight: screenHeight,
      );

  void _changed() {
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'systems': {for (final e in _systems.entries) e.key: e.value.name},
        }),
      );
    } on Object catch (e) {
      debugPrint('Presets not saved: $e');
    }
  }
}

/// A game starting with [plan]: the preset's run-ahead frames with the
/// method chosen in Settings. Nothing for a system that does not run ahead.
void applyPresetRunAhead(RunAheadSettings settings, PresetPlan plan) {
  final frames = plan.runAhead;
  if (frames == null) return;
  settings.sink?.call(frames == 0 ? 0 : settings.method.hostCode, frames);
}

/// The game ended: back to the Settings choice.
void restoreRunAhead(RunAheadSettings settings) => settings.sink?.call(
  settings.frames == 0 ? 0 : settings.method.hostCode,
  settings.frames,
);

/// Gives Settings and the session the presets; absent off the desktop.
class DeckPresetsScope extends InheritedNotifier<DeckPresetSettings> {
  const DeckPresetsScope({
    super.key,
    required DeckPresetSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static DeckPresetSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeckPresetsScope>()?.notifier;
}

/// The screen the app is on: height in physical pixels and refresh in Hz.
({double height, double refresh}) screenOf(BuildContext context) {
  final display = View.maybeOf(context)?.display;
  return (
    height: display == null || display.size.height <= 0
        ? 800
        : display.size.height,
    refresh: display == null || display.refreshRate <= 0
        ? 60
        : display.refreshRate,
  );
}

String _presetLabel(DeckPreset? p) => p == null ? 'per system' : p.name;

/// The `PRESETS ....... BALANCED · STEAM DECK OLED >` row of the settings.
class PresetsTile extends StatelessWidget {
  const PresetsTile({super.key, required this.settings});

  final DeckPresetSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => CfgRow(
      label: 'Presets',
      value: [
        _presetLabel(settings.common),
        if (settings.model != DeckModel.none) settings.model.label,
      ].join(' · '),
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PresetsPage(settings: settings),
        ),
      ),
    ),
  );
}

/// The device, an ALL row, and one row per system with what its preset
/// picks. A on a system steps its preset.
class PresetsPage extends StatelessWidget {
  const PresetsPage({super.key, required this.settings});

  final DeckPresetSettings settings;

  static const _choices = DeckPreset.values;

  @override
  Widget build(BuildContext context) {
    final screen = screenOf(context);
    final deck = settings.model != DeckModel.none;
    final hz = screen.refresh.round();
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Shortcuts(
        shortcuts: arrowsMoveFocus,
        child: CfgPage(
          title: 'Presets',
          path: const ['settings', 'video.cfg', 'presets'],
          sections: [
            CfgTable(
              header: 'PRESETS.CFG',
              rows: [
                CfgRow(
                  label: 'Device',
                  control: Text(
                    deck
                        ? '${settings.model.label} · '
                                  '${settings.model.minHz}-'
                                  '${settings.model.maxHz} Hz'
                              .toUpperCase()
                        : 'PC',
                  ),
                ),
                CfgRow(label: 'Display', control: Text('$hz HZ')),
                CfgRow(
                  label: 'All systems',
                  // The D-pad starts on the ALL choices.
                  control: AutofocusFirst(
                    child: CfgSegment<DeckPreset?>(
                      values: _choices,
                      selected: settings.common,
                      labelOf: (p) => p!.name,
                      onChanged: (p) => settings.setAll(p!),
                    ),
                  ),
                ),
              ],
            ),
            BrutalTable(
              shrinkWrap: true,
              columns: const [
                BrutalColumn('System', width: 88),
                BrutalColumn('Preset', flex: 1),
                BrutalColumn('Res', width: 64),
                BrutalColumn('Run-ahead', width: 112),
                BrutalColumn('Refresh', width: 96),
                BrutalColumn('TDP', width: 64),
              ],
              rowCount: presetSystems.length,
              onRowPressed: (i) {
                final s = presetSystems[i];
                settings.setPreset(s, settings.presetOf(s).next);
              },
              cellBuilder: (context, row, column, lit) {
                final system = presetSystems[row];
                final preset = settings.presetOf(system);
                final plan = settings.planFor(
                  system,
                  screenHeight: screen.height,
                );
                return Text(switch (column) {
                  0 => presetSystemLabel(system),
                  1 => '[${preset.name.toUpperCase()}]',
                  2 when plan == null => 'own',
                  2 =>
                    plan!.upscale == 0
                        ? (upscaleFactors(system, desktop: true).isEmpty
                              ? 'native'
                              : 'auto')
                        : '${plan.upscale}x',
                  3 when plan == null => 'own',
                  3 => switch (plan!.runAhead) {
                    null => '—',
                    0 => 'off',
                    final f => '$f frame${f == 1 ? '' : 's'}',
                  },
                  4 => plan?.refreshHz == null ? '—' : '${plan!.refreshHz} Hz',
                  _ => plan?.tdpWatts == null ? '—' : '${plan!.tdpWatts} W',
                });
              },
            ),
            if (!dividesEvenly(screen.refresh))
              LogLine(
                'Display at $hz Hz: 60 fps games judder. '
                '${deck ? 'Set 60 Hz' : 'Use 60 or 120 Hz, or VRR'}.',
                status: LogStatus.err,
              ),
            if (deck)
              const LogLine(
                'Set the TDP limit and refresh rate in Steam: ... button > '
                'Performance, with "Use per-game profile" on for Dena.emu.',
              ),
            const LogLine(
              'A steps a system\'s preset. OFF keeps your own RES and '
              'run-ahead; a game\'s own RES choice beats its preset. PAL '
              'games run at 50 fps: 50 Hz.',
            ),
          ],
        ),
      ),
    );
  }
}
