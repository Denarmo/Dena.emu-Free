// SPDX-License-Identifier: GPL-3.0-or-later
// The chosen shader per system and per game.
// Spec: docs/specs/shaders.md (App)
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../shell/platform_features.dart';
import 'shader_catalog.dart';

/// `<dataDir>/shaders.json`, shaped as
/// `{"systems": {"<system>": "<id>"}, "games": {"<sha1>": "<id>"}}`, plus
/// `"upscale": {"systems": {"<system>": 2}, "games": {"<sha1>": 0}}` and
/// `"widescreen": {"systems": {"<system>": true}, "games": {"<sha1>": false}}`
/// (desktop-resolution.md). A game override of "" is Off for that game; an
/// upscale of 0 is the core's default resolution.
///
/// The file is a few hundred bytes and is read before the first frame, so
/// it is read and written synchronously; that also keeps widget tests free of
/// real async IO.
class ShaderStore {
  /// [desktop] picks the desktop's resolution and widescreen choices
  /// ([desktopResolution] when null).
  ShaderStore(this.dataDir, {bool? desktop})
    : desktop = desktop ?? desktopResolution;

  final String dataDir;
  final bool desktop;

  File get _file => File(p.join(dataDir, 'shaders.json'));

  _Choices _read() {
    final empty = _Choices({}, {}, {}, {}, {}, {});
    try {
      if (!_file.existsSync()) return empty;
      final j = jsonDecode(_file.readAsStringSync());
      if (j is! Map) return empty;
      Map<String, String> strings(Object? m) => {
        if (m is Map)
          for (final e in m.entries)
            if (e.value is String) '${e.key}': e.value as String,
      };
      Map<String, int> ints(Object? m) => {
        if (m is Map)
          for (final e in m.entries)
            if (e.value is int) '${e.key}': e.value as int,
      };
      Map<String, bool> bools(Object? m) => {
        if (m is Map)
          for (final e in m.entries)
            if (e.value is bool) '${e.key}': e.value as bool,
      };
      final up = j['upscale'] is Map ? j['upscale'] as Map : const {};
      final wide = j['widescreen'] is Map ? j['widescreen'] as Map : const {};
      return _Choices(
        strings(j['systems']),
        strings(j['games']),
        ints(up['systems']),
        ints(up['games']),
        bools(wide['systems']),
        bools(wide['games']),
      );
    } on Object {
      // A damaged file counts as no choices; the next save rewrites it.
      return empty;
    }
  }

  void _write(_Choices c) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      jsonEncode({
        'systems': c.systems,
        'games': c.games,
        if (c.upSystems.isNotEmpty || c.upGames.isNotEmpty)
          'upscale': {'systems': c.upSystems, 'games': c.upGames},
        if (c.wideSystems.isNotEmpty || c.wideGames.isNotEmpty)
          'widescreen': {'systems': c.wideSystems, 'games': c.wideGames},
      }),
    );
  }

  String _known(String? id) =>
      id != null && shaderById(id, desktop: desktop) != null ? id : '';

  /// The shader for a game: its override, else the system default, else Off
  /// (""). Unknown ids are Off.
  String resolve(String system, String sha1) {
    final r = _read();
    return _known(r.games[sha1] ?? r.systems[system]);
  }

  /// The system default ("" when none).
  String systemDefault(String system) => _known(_read().systems[system]);

  /// Whether [sha1] has its own choice (possibly Off).
  bool hasGameOverride(String sha1) => _read().games.containsKey(sha1);

  /// Sets the default for [system]; "" removes it.
  void setSystem(String system, String id) {
    final r = _read();
    if (id.isEmpty) {
      r.systems.remove(system);
    } else {
      r.systems[system] = id;
    }
    _write(r);
  }

  /// Overrides the shader of one game; "" is Off for that game.
  void setGame(String sha1, String id) {
    final r = _read();
    r.games[sha1] = id;
    _write(r);
  }

  /// Makes the game follow its system default again.
  void clearGame(String sha1) {
    final r = _read();
    if (r.games.remove(sha1) == null) return;
    _write(r);
  }

  // ---- Internal resolution (shaders.md, Upscale) ----

  /// The factor a game starts with: its own choice, else the system default,
  /// else 0 (the core's default), capped at what the system can do.
  int resolveUpscale(String system, String sha1) {
    final r = _read();
    return _cap(system, r.upGames[sha1] ?? r.upSystems[system] ?? 0);
  }

  int systemUpscale(String system) =>
      _cap(system, _read().upSystems[system] ?? 0);

  bool hasGameUpscale(String sha1) => _read().upGames.containsKey(sha1);

  /// Sets the default for [system]; 0 removes it.
  void setSystemUpscale(String system, int factor) {
    final r = _read();
    if (factor == 0) {
      r.upSystems.remove(system);
    } else {
      r.upSystems[system] = factor;
    }
    _write(r);
  }

  void setGameUpscale(String sha1, int factor) {
    final r = _read();
    r.upGames[sha1] = factor;
    _write(r);
  }

  void clearGameUpscale(String sha1) {
    final r = _read();
    if (r.upGames.remove(sha1) == null) return;
    _write(r);
  }

  /// The offered factor at or below [f]; 0 below 2 or where the system
  /// draws native only (desktop-resolution.md: PSX 6x is 4x).
  int _cap(String system, int f) {
    var best = 0;
    for (final x in upscaleFactors(system, desktop: desktop)) {
      if (x <= f) best = x;
    }
    return best;
  }

  // ---- Widescreen (desktop-resolution.md) ----

  /// Whether a game starts with the core's 16:9 hack: its own choice, else
  /// the system default, else off; always off where the system has none.
  bool resolveWidescreen(String system, String sha1) {
    if (!hasWidescreen(system, desktop: desktop)) return false;
    final r = _read();
    return r.wideGames[sha1] ?? r.wideSystems[system] ?? false;
  }

  bool systemWidescreen(String system) =>
      hasWidescreen(system, desktop: desktop) &&
      (_read().wideSystems[system] ?? false);

  bool hasGameWidescreen(String sha1) => _read().wideGames.containsKey(sha1);

  /// Sets the default for [system]; off removes it.
  void setSystemWidescreen(String system, bool on) {
    final r = _read();
    if (on) {
      r.wideSystems[system] = true;
    } else {
      r.wideSystems.remove(system);
    }
    _write(r);
  }

  void setGameWidescreen(String sha1, bool on) {
    final r = _read();
    r.wideGames[sha1] = on;
    _write(r);
  }

  void clearGameWidescreen(String sha1) {
    final r = _read();
    if (r.wideGames.remove(sha1) == null) return;
    _write(r);
  }
}

class _Choices {
  _Choices(
    this.systems,
    this.games,
    this.upSystems,
    this.upGames,
    this.wideSystems,
    this.wideGames,
  );

  final Map<String, String> systems, games;
  final Map<String, int> upSystems, upGames;
  final Map<String, bool> wideSystems, wideGames;
}

/// Whether the app offers the desktop's resolution and widescreen choices:
/// the stock Windows or Linux runner with the desktop host library
/// (desktop-resolution.md). Tests on a desktop host keep the phone's.
bool get desktopResolution =>
    !hasAndroidShell && shellProfile == ShellProfile.desktop;

/// The internal-resolution factors offered for [system] besides Auto
/// (shaders.md, Upscale; desktop-resolution.md); empty when it draws only at
/// native size. Mirrors the host's table in host/runner/runner.cpp. Phones
/// stop at 4x; the desktop's cores go to 8x, and GB/GBC stay native there
/// (their xBRZ filter is the Android renderer's).
List<int> upscaleFactors(String system, {bool? desktop}) =>
    (desktop ?? desktopResolution)
    ? switch (system) {
        'n64' ||
        'psp' ||
        'nds' ||
        'dreamcast' ||
        'gamecube' ||
        'wii' => const [2, 3, 4, 6, 8],
        'psx' || 'ps2' => const [2, 4, 8], // Beetle PSX HW, LRPS2: 2x-8x
        _ => const [],
      }
    : switch (system) {
        'n64' || 'psp' => const [2, 3, 4],
        'gb' || 'gbc' || 'nds' => const [2, 3, 4],
        'psx' => const [2],
        _ => const [],
      };

/// Highest internal-resolution factor per system; 1 when it draws only at
/// native size. [filterUpscale] systems use the xBRZ filter.
int maxUpscale(String system, {bool? desktop}) {
  final f = upscaleFactors(system, desktop: desktop);
  return f.isEmpty ? 1 : f.last;
}

/// Systems whose core has no resolution option: 2x-4x run the frame through
/// the xBRZ pixel-art filter before the shader (shaders.md, Upscale). Phones
/// only: the desktop draws them native.
bool filterUpscale(String system, {bool? desktop}) =>
    !(desktop ?? desktopResolution) && (system == 'gb' || system == 'gbc');

/// Systems whose core has a 16:9 widescreen hack the app offers
/// (desktop-resolution.md): desktop N64, PSX, Dreamcast, PS2, GameCube and
/// Wii.
bool hasWidescreen(String system, {bool? desktop}) =>
    (desktop ?? desktopResolution) &&
    const {
      'n64',
      'psx',
      'dreamcast',
      'ps2',
      'gamecube',
      'wii',
    }.contains(system);

/// Systems whose 2x-4x switch to a GPU renderer with its own requirement,
/// named in the resolution note (ds.md, Internal resolution). Desktop GPUs
/// all have desktop OpenGL, so there is none to name.
String? upscaleRequirement(String system, {bool? desktop}) =>
    (desktop ?? desktopResolution)
    ? null
    : switch (system) {
        'nds' => 'OpenGL ES 3.2',
        _ => null,
      };
