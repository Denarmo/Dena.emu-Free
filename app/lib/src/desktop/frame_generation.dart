// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > VIDEO.CFG > Frame generation (experimental; Windows and
// SteamOS): one generated frame between every two real ones on a screen at
// least twice as fast as the game, per system, with a latency gate in the
// host that turns it off.
// Spec: docs/specs/frame-generation.md
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import '../shell/host_library.dart';
import '../shell/platform_features.dart';
import '../ui/brutal/brutal.dart';
import 'deck_presets.dart';

/// What the host makes between two real frames.
enum FrameGenMode {
  off(0, 'Off'),

  /// Motion-compensated blend (optical flow).
  interpolate(1, 'Interpolate'),

  /// Whole game pixels moved, never blended.
  pixelArt(2, 'Pixel-art');

  const FrameGenMode(this.hostCode, this.label);

  final int hostCode;
  final String label;
}

/// Systems on the page (the shader page's systems, desktop).
const frameGenSystems = presetSystems;

/// Below this many screen refreshes per game frame the host does not
/// generate (frame-generation.md, Timing).
const frameGenMinRatio = 1.98;

/// The game rate of every system on the page (PAL games: 50 fps, which a
/// 100 Hz screen doubles).
double frameGenFps(String system) => contentFps.toDouble();

/// Whether a [refresh] Hz screen is fast enough for [system].
bool frameGenOffered(String system, double refresh) =>
    refresh >= frameGenMinRatio * frameGenFps(system);

/// The host's view: `"<mode> <reason or -> <p95 added ms> <limit ms>"`.
typedef FrameGenStatus = ({
  int mode,
  String reason,
  double addedMs,
  double limitMs,
});

FrameGenStatus? parseFrameGenStatus(String? text) {
  final parts = (text ?? '').trim().split(' ');
  if (parts.length < 4) return null;
  final mode = int.tryParse(parts[0]);
  final added = double.tryParse(parts[2]);
  final limit = double.tryParse(parts[3]);
  if (mode == null || added == null || limit == null) return null;
  return (
    mode: mode,
    reason: parts[1] == '-' ? '' : parts[1],
    addedMs: added,
    limitMs: limit,
  );
}

/// The reason shown under a system the host turned off; null for reasons
/// that are not kept ("refresh" depends on the screen, not the system).
String? frameGenFallbackMessage(FrameGenStatus s) => switch (s.reason) {
  'latency' =>
    'Turned off: added ${s.addedMs.round()} ms of input lag '
        '(limit ${s.limitMs.round()} ms)',
  'gl' => "Turned off: this PC's graphics driver can't run it",
  _ => null,
};

/// The host library's two calls (desktop.h).
class FrameGenHost {
  const FrameGenHost({required this.setMode, required this.status});

  final void Function(int mode) setMode;
  final String Function() status;
}

/// The choice per system and the kept fallbacks, in
/// `desktop_frame_generation.json` in the data folder. Off everywhere by
/// default.
class FrameGenSettings extends ChangeNotifier {
  FrameGenSettings({
    this.file,
    this.host,
    Map<String, FrameGenMode>? modes,
    Map<String, String>? fallbacks,
  }) : _modes = {...?modes},
       _fallbacks = {...?fallbacks};

  /// Reads [file]; a missing or damaged file gives Off everywhere.
  factory FrameGenSettings.load(File file, {FrameGenHost? host}) {
    final modes = <String, FrameGenMode>{};
    final fallbacks = <String, String>{};
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map) {
          if (j['modes'] case final Map m) {
            for (final MapEntry(:key, :value) in m.entries) {
              for (final mode in FrameGenMode.values) {
                if (mode.name == value && mode != FrameGenMode.off) {
                  modes['$key'] = mode;
                }
              }
            }
          }
          if (j['fallbacks'] case final Map f) {
            for (final MapEntry(:key, :value) in f.entries) {
              if (value is String) fallbacks['$key'] = value;
            }
          }
        }
      }
    } on Object {
      // Off everywhere; the next change rewrites the file.
    }
    return FrameGenSettings(
      file: file,
      host: host,
      modes: modes,
      fallbacks: fallbacks,
    );
  }

  final File? file;
  final FrameGenHost? host;
  final Map<String, FrameGenMode> _modes;
  final Map<String, String> _fallbacks;
  String? _playing;

  FrameGenMode modeOf(String system) => _modes[system] ?? FrameGenMode.off;

  /// Why the host turned [system] off, until its choice changes.
  String? fallbackOf(String system) => _fallbacks[system];

  /// Systems with frame generation on.
  int get systemsOn => _modes.length;

  void setMode(String system, FrameGenMode mode) {
    if (modeOf(system) == mode && !_fallbacks.containsKey(system)) return;
    if (mode == FrameGenMode.off) {
      _modes.remove(system);
    } else {
      _modes[system] = mode;
    }
    _fallbacks.remove(system);
    _changed();
  }

  /// A game of [system] starts: its mode goes to the host.
  void startGame(String system) {
    _playing = system;
    host?.setMode(modeOf(system).hostCode);
  }

  /// While a game plays (every 2 s) and when it ends: a latency or GL
  /// fallback from the host turns the system back to Off and keeps why.
  void checkStatus() {
    final system = _playing;
    final h = host;
    if (system == null || h == null || modeOf(system) == FrameGenMode.off) {
      return;
    }
    final s = parseFrameGenStatus(h.status());
    if (s == null || s.mode != 0) return;
    final message = frameGenFallbackMessage(s);
    if (message == null) return;
    _modes.remove(system);
    _fallbacks[system] = message;
    _changed();
  }

  /// The game ended: off in the host.
  void endGame() {
    checkStatus();
    _playing = null;
    host?.setMode(0);
  }

  void _changed() {
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'modes': {for (final e in _modes.entries) e.key: e.value.name},
          'fallbacks': _fallbacks,
        }),
      );
    } on Object catch (e) {
      debugPrint('Frame generation settings not saved: $e');
    }
  }
}

/// dena_desktop_set_frame_generation and its status in the host library;
/// null off the desktop or with a library that predates them.
FrameGenHost? openFrameGenHost() {
  if (shellProfile != ShellProfile.desktop) return null;
  final lib = openHostLibrary();
  if (lib == null) return null;
  try {
    final set = lib.lookupFunction<Void Function(Int32), void Function(int)>(
      'dena_desktop_set_frame_generation',
    );
    final status = lib
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'dena_desktop_frame_generation_status',
        );
    return FrameGenHost(
      setMode: (m) => set(m),
      status: () => status().toDartString(),
    );
  } on ArgumentError {
    return null;
  }
}

/// Gives Settings and the session the frame generation choice; absent off
/// the desktop.
class FrameGenScope extends InheritedNotifier<FrameGenSettings> {
  const FrameGenScope({
    super.key,
    required FrameGenSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static FrameGenSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FrameGenScope>()?.notifier;
}

/// `2 systems` or `off`.
String frameGenSummary(FrameGenSettings s) => switch (s.systemsOn) {
  0 => 'off',
  1 => '1 system',
  final n => '$n systems',
};

/// The `FRAME GENERATION (EXPERIMENTAL) ..... OFF >` row of VIDEO.CFG.
class FrameGenTile extends StatelessWidget {
  const FrameGenTile({super.key, required this.settings, this.model});

  final FrameGenSettings settings;
  final DeckModel? model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => CfgRow(
      label: 'Frame generation (experimental)',
      value: frameGenSummary(settings),
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              FrameGenPage(settings: settings, model: model ?? DeckModel.none),
        ),
      ),
    ),
  );
}

/// The Deck screens, too slow to double 60 fps.
String? deckFrameGenNote(DeckModel model) => switch (model) {
  DeckModel.none => null,
  _ =>
    'The ${model.label} screen runs at up to ${model.maxHz} Hz, under twice '
        '60 fps. Frame generation works on a 120 Hz external screen.',
};

/// The sticker, the screen's refresh, one OFF / INTERPOLATE / PIXEL-ART row
/// per system, and why a system was turned off.
class FrameGenPage extends StatelessWidget {
  const FrameGenPage({
    super.key,
    required this.settings,
    this.model = DeckModel.none,
    this.refresh,
  });

  final FrameGenSettings settings;
  final DeckModel model;

  /// The screen's refresh in Hz; the window's display when null.
  final double? refresh;

  @override
  Widget build(BuildContext context) {
    final hz = refresh ?? screenOf(context).refresh;
    final note = deckFrameGenNote(model);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final offered = [
          for (final s in frameGenSystems) frameGenOffered(s, hz),
        ];
        final first = offered.indexOf(true);
        return Shortcuts(
          shortcuts: arrowsMoveFocus,
          child: CfgPage(
            title: 'Frame generation',
            path: const ['settings', 'video.cfg', 'frame-gen'],
            sections: [
              CfgTable(
                header: 'FRAME_GEN.CFG',
                rows: [
                  const CfgRow(
                    label: 'Status',
                    control: Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Sticker('Experimental', small: true, angle: -2),
                    ),
                  ),
                  CfgRow(label: 'Screen', control: Text('${hz.round()} HZ')),
                  for (final (i, system) in frameGenSystems.indexed)
                    CfgRow(
                      label: presetSystemLabel(system),
                      // The D-pad starts on the first system it can change.
                      control: AutofocusFirst(
                        enabled: i == first,
                        child: CfgSegment<FrameGenMode>(
                          values: FrameGenMode.values,
                          selected: settings.modeOf(system),
                          labelOf: (m) => m.label,
                          onChanged: offered[i]
                              ? (m) => settings.setMode(system, m)
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (first < 0)
                    LogLine(
                      'Screen at ${hz.round()} Hz: needs 120 Hz (twice the '
                      "game's 60 fps). Choices are kept for a faster screen.",
                      status: LogStatus.err,
                    ),
                  ?(note == null ? null : LogLine(note)),
                  for (final system in frameGenSystems)
                    if (settings.fallbackOf(system) case final why?)
                      LogLine(
                        '${presetSystemLabel(system)}: $why',
                        status: LogStatus.err,
                      ),
                  const LogLine(
                    'Shows a made-up frame between every two real ones: '
                    'motion looks twice as smooth. Interpolate blends; '
                    'Pixel-art moves whole pixels, so sprites stay sharp. '
                    'Adds one screen refresh of input lag (about 8 ms at '
                    '120 Hz); run-ahead hides more than that. Turns itself '
                    'off when a game gets too slow to answer.',
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
