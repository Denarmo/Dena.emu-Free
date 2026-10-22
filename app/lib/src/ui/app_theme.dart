// SPDX-License-Identifier: GPL-3.0-or-later
// The app's colour choices: Paper, Ink or System mode and the accent swap
// (hazard yellow or Dena gold), saved with the library view and audio
// latency.
// Spec: docs/specs/theming.md, docs/specs/brutalist-ui.md
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'brutal/tokens.dart';

/// The brand gold. In the app it is only the optional accent swap
/// ([BrutalAccent.gold]); the app icon keeps it.
const Color denaAccent = Color(0xFFF1C40F);

/// The brand's dark base colour (Dark Anthracite), kept for the app icon.
const Color denaAnthracite = Color(0xFF202024);

/// Material's [ColorScheme] read from the Brutalist [t]okens, so stock
/// widgets come out right before each screen is restyled
/// (brutalist-ui.md 2.1).
ColorScheme brutalScheme(BrutalTokens t) => ColorScheme(
  brightness: t.dark ? Brightness.dark : Brightness.light,
  primary: t.primary,
  onPrimary: t.onPrimary,
  primaryContainer: t.focus,
  onPrimaryContainer: t.onFocus,
  secondary: t.focus,
  onSecondary: t.onFocus,
  secondaryContainer: t.focus,
  onSecondaryContainer: t.onFocus,
  tertiary: t.primary,
  onTertiary: t.onPrimary,
  error: t.danger,
  onError: const Color(0xFFFFFFFF),
  errorContainer: t.danger,
  onErrorContainer: const Color(0xFFFFFFFF),
  surface: t.ground,
  onSurface: t.ink,
  onSurfaceVariant: t.mutedText,
  surfaceDim: t.ground,
  surfaceBright: t.panel,
  surfaceContainerLowest: t.panel,
  surfaceContainerLow: t.panel,
  surfaceContainer: t.panel,
  surfaceContainerHigh: t.panel,
  surfaceContainerHighest: t.panel,
  surfaceTint: const Color(0x00000000),
  outline: t.ink,
  outlineVariant: t.muted,
  shadow: t.shadow,
  scrim: const Color(0xFF000000),
  inverseSurface: t.headerBar,
  onInverseSurface: t.onHeaderBar,
  inversePrimary: t.focus,
);

/// WCAG contrast ratio of two opaque colours (1 to 21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Audio buffer targets offered in Settings, in ms (performance.md).
const audioLatencyOptions = [40, 30, 20];

/// The default audio buffer target, in ms (performance.md).
const defaultAudioLatency = 40;

/// How the Games tab lists the library (brutalist-ui.md 4.2): the table by
/// default, the box grid or the stash as options.
enum LibraryView { table, grid, stash }

/// The chosen mode (Paper, Ink or System), accent, library view and audio
/// latency, saved to `<dataDir>/theme.json` as JSON. Paper, hazard accent,
/// the table and a 40 ms audio buffer by default. Without a [file] (tests)
/// choices last for the session.
///
/// Older files (before the Brutalist redesign) wrote `mode` as
/// `dark`/`light`/`system` and a `palette`: dark loads as Ink, light as
/// Paper; the palette (Dena gold, Material You, console themes) is dropped
/// and loads as the hazard accent. `"library": "stash"` still picks the
/// stash.
///
/// The file is a few bytes and is read before the first frame, so it is read
/// and written synchronously, like the shader store.
class ThemeSettings extends ChangeNotifier {
  ThemeSettings({
    this.file,
    this._mode = ThemeMode.light,
    this._accent = BrutalAccent.hazard,
    LibraryView? library,
    int? audioLatencyMs,
    bool stash = false,
  }) : _library = library ?? (stash ? LibraryView.stash : LibraryView.table),
       _audioLatencyMs = audioLatencyMs ?? defaultAudioLatency;

  /// Reads [file]; a missing or damaged file gives the defaults.
  factory ThemeSettings.load(File file) {
    var mode = ThemeMode.light;
    var accent = BrutalAccent.hazard;
    var library = LibraryView.table;
    var audioLatency = defaultAudioLatency;
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map) {
          mode = modeFromName(j['mode']) ?? mode;
          final a = j['accent'];
          accent = BrutalAccent.values.firstWhere(
            (v) => v.name == a,
            orElse: () => BrutalAccent.hazard,
          );
          final l = j['library'];
          library = LibraryView.values.firstWhere(
            (v) => v.name == l,
            orElse: () => LibraryView.table,
          );
          final ms = j['audioLatencyMs'];
          if (ms is int && audioLatencyOptions.contains(ms)) {
            audioLatency = ms;
          }
        }
      }
    } on Object {
      // Defaults; the next change rewrites the file.
    }
    return ThemeSettings(
      file: file,
      mode: mode,
      accent: accent,
      library: library,
      audioLatencyMs: audioLatency,
    );
  }

  /// The mode saved as [name]: `paper`, `ink`, `system`, or the
  /// pre-Brutalist `light`/`dark`. Null for anything else.
  static ThemeMode? modeFromName(Object? name) => switch (name) {
    'paper' || 'light' => ThemeMode.light,
    'ink' || 'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => null,
  };

  /// The name [mode] is saved as.
  static String modeName(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'paper',
    ThemeMode.dark => 'ink',
    ThemeMode.system => 'system',
  };

  final File? file;
  ThemeMode _mode;
  BrutalAccent _accent;
  LibraryView _library;
  int _audioLatencyMs;

  /// Paper is [ThemeMode.light], Ink [ThemeMode.dark].
  ThemeMode get mode => _mode;

  set mode(ThemeMode value) {
    if (value == _mode) return;
    _mode = value;
    _save();
  }

  /// The focus and selection colour.
  BrutalAccent get accent => _accent;

  set accent(BrutalAccent value) {
    if (value == _accent) return;
    _accent = value;
    _save();
  }

  /// How the Games tab lists the library.
  LibraryView get library => _library;

  set library(LibraryView value) {
    if (value == _library) return;
    _library = value;
    _save();
  }

  /// Whether the Games tab shows the stash. Turning it off picks the grid,
  /// the other view the tab offers until the table lands.
  bool get stash => _library == LibraryView.stash;

  set stash(bool value) =>
      library = value ? LibraryView.stash : LibraryView.grid;

  int get audioLatencyMs => _audioLatencyMs;

  set audioLatencyMs(int value) {
    if (value == _audioLatencyMs || !audioLatencyOptions.contains(value)) {
      return;
    }
    _audioLatencyMs = value;
    _save();
  }

  void _save() {
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'mode': modeName(_mode),
          'accent': _accent.name,
          'library': _library.name,
          'audioLatencyMs': _audioLatencyMs,
        }),
      );
    } on Object catch (e) {
      debugPrint('Theme not saved: $e');
    }
  }
}

/// Gives the settings screens the app's [ThemeSettings].
class ThemeScope extends InheritedNotifier<ThemeSettings> {
  const ThemeScope({
    super.key,
    required ThemeSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static ThemeScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()!;
}
