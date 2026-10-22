// SPDX-License-Identifier: GPL-3.0-or-later
// Installed DAT files per system: download from libretro-database, import,
// remove, and the parsed index.
// Spec: docs/specs/rom-manager.md
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/box_art.dart' show Fetch, httpFetch;
import 'dat.dart';

/// The libretro-database commit DATs download from (same as the box-art
/// index).
const datCommit = '12c21cf79f1e20eff6ac68b80875816c717d0a7a';

/// Our system id -> DAT set and libretro-database DAT name.
const datSystems = <String, ({String set, String name})>{
  'nes': (set: 'no-intro', name: 'Nintendo - Nintendo Entertainment System'),
  'snes': (
    set: 'no-intro',
    name: 'Nintendo - Super Nintendo Entertainment System',
  ),
  'gb': (set: 'no-intro', name: 'Nintendo - Game Boy'),
  'gbc': (set: 'no-intro', name: 'Nintendo - Game Boy Color'),
  'gba': (set: 'no-intro', name: 'Nintendo - Game Boy Advance'),
  'nds': (set: 'no-intro', name: 'Nintendo - Nintendo DS'),
  'n64': (set: 'no-intro', name: 'Nintendo - Nintendo 64'),
  'genesis': (set: 'no-intro', name: 'Sega - Mega Drive - Genesis'),
  'psx': (set: 'redump', name: 'Sony - PlayStation'),
  'psp': (set: 'redump', name: 'Sony - PlayStation Portable'),
  'saturn': (set: 'redump', name: 'Sega - Saturn'),
  'dreamcast': (set: 'redump', name: 'Sega - Dreamcast'),
  'gamecube': (set: 'redump', name: 'Nintendo - GameCube'),
  'wii': (set: 'redump', name: 'Nintendo - Wii'),
  'ps2': (set: 'redump', name: 'Sony - PlayStation 2'),
};

/// The system a DAT header name is for, or null. The name may carry a
/// suffix such as ` (Parent-Clone)`, ` (20240101-000000)` or
/// ` - Datfile (10885) (…)`; the longest matching system name wins, so
/// `Nintendo - Game Boy Color` is never `gb`.
String? systemForDatName(String headerName) {
  final name = headerName.trim().toLowerCase();
  String? best;
  var bestLength = 0;
  for (final MapEntry(:key, :value) in datSystems.entries) {
    final known = value.name.toLowerCase();
    if (known.length <= bestLength) continue;
    if (name == known ||
        name.startsWith('$known (') ||
        name.startsWith('$known - ')) {
      best = key;
      bestLength = known.length;
    }
  }
  return best;
}

/// What is installed for one system (`romtools/dats/<system>.json`).
class DatInfo {
  const DatInfo({
    required this.system,
    required this.name,
    required this.source,
    required this.installedAt,
    required this.games,
    this.version,
    this.url,
  });

  final String system;

  /// The DAT's header name.
  final String name;
  final String? version;

  /// `libretro-database (No-Intro)`, `libretro-database (Redump)` or
  /// `imported <file name>`.
  final String source;

  /// Where it was downloaded from; null when imported.
  final String? url;
  final DateTime installedAt;

  /// How many games the DAT lists.
  final int games;

  Map<String, Object?> toJson() => {
    'system': system,
    'name': name,
    'version': version,
    'source': source,
    'url': url,
    'installedAt': installedAt.toIso8601String(),
    'games': games,
  };

  static DatInfo? fromJson(Object? json) {
    if (json case {
      'system': final String system,
      'name': final String name,
      'source': final String source,
      'installedAt': final String at,
      'games': final int games,
    }) {
      final when = DateTime.tryParse(at);
      if (when == null) return null;
      return DatInfo(
        system: system,
        name: name,
        version: (json as Map)['version'] as String?,
        source: source,
        url: json['url'] as String?,
        installedAt: when,
        games: games,
      );
    }
    return null;
  }
}

/// The DATs installed under `<dataDir>/romtools/dats/`.
class DatStore extends ChangeNotifier {
  DatStore(this.dataDir, {this.fetch = httpFetch, this.clock = DateTime.now});

  final String dataDir;
  final Fetch fetch;
  final DateTime Function() clock;

  final _infos = <String, DatInfo>{};
  final _busy = <String>{};
  final _indexes = <String, Future<DatIndex?>>{};

  String get _dir => p.join(dataDir, 'romtools', 'dats');

  File _datFile(String system) => File(p.join(_dir, '$system.dat'));
  File _jsonFile(String system) => File(p.join(_dir, '$system.json'));

  /// Reads the installed DATs' info files.
  Future<void> load() async {
    _infos.clear();
    final dir = Directory(_dir);
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is! File || p.extension(f.path) != '.json') continue;
        try {
          final info = DatInfo.fromJson(jsonDecode(await f.readAsString()));
          if (info != null && datSystems.containsKey(info.system)) {
            _infos[info.system] = info;
          }
        } on Object {
          // A damaged info file counts as not installed.
        }
      }
    }
    notifyListeners();
  }

  /// The installed DATs, in [datSystems] order.
  List<DatInfo> get installed => [for (final s in datSystems.keys) ?_infos[s]];

  /// What is installed for [system], or null.
  DatInfo? info(String system) => _infos[system];

  /// Whether a download or import is running for [system].
  bool busy(String system) => _busy.contains(system);

  /// The libretro-database URL of [system]'s DAT, at [datCommit] or, with
  /// [latest], at `master`.
  Uri urlFor(String system, {bool latest = false}) {
    final d = datSystems[system];
    if (d == null) throw ArgumentError.value(system, 'system', 'No DAT');
    final ref = latest ? 'master' : datCommit;
    return Uri.parse(
      'https://raw.githubusercontent.com/libretro/libretro-database/$ref/'
      'metadat/${d.set}/${Uri.encodeComponent(d.name)}.dat',
    );
  }

  /// Downloads [system]'s DAT (from `master` with [latest]) and installs it.
  Future<DatInfo> download(String system, {bool latest = false}) async {
    final d = datSystems[system];
    if (d == null) throw ArgumentError.value(system, 'system', 'No DAT');
    final url = urlFor(system, latest: latest);
    return _run(system, () async {
      final bytes = await fetch(url);
      if (bytes == null) {
        throw StateError('No DAT for ${d.name} on the server');
      }
      final (name, version, games) = await _check(bytes);
      return _install(
        bytes,
        DatInfo(
          system: system,
          name: name.isEmpty ? d.name : name,
          version: version,
          source: d.set == 'redump'
              ? 'libretro-database (Redump)'
              : 'libretro-database (No-Intro)',
          url: url.toString(),
          installedAt: clock(),
          games: games,
        ),
      );
    });
  }

  /// Installs the user's own DAT [file] (XML, ClrMamePro or a zip of one),
  /// replacing the stored one for its system.
  Future<DatInfo> importFile(File file) async {
    final bytes = await file.readAsBytes();
    final (name, version, games) = await _check(bytes);
    final system = systemForDatName(name);
    if (system == null) {
      throw FormatException(
        "This DAT is for '$name', which Dena.emu doesn't play",
      );
    }
    return _run(
      system,
      () => _install(
        bytes,
        DatInfo(
          system: system,
          name: name,
          version: version,
          source: 'imported ${p.basename(file.path)}',
          installedAt: clock(),
          games: games,
        ),
      ),
    );
  }

  /// Deletes [system]'s DAT.
  Future<void> remove(String system) async {
    for (final f in [_datFile(system), _jsonFile(system)]) {
      if (await f.exists()) await f.delete();
    }
    _infos.remove(system);
    _indexes.remove(system);
    notifyListeners();
  }

  /// [system]'s parsed DAT, or null when none is installed. Parsed once, in
  /// an isolate, and kept in memory.
  Future<DatIndex?> indexFor(String system) {
    if (!_infos.containsKey(system)) return Future.value(null);
    final file = _datFile(system);
    return _indexes[system] ??= () async {
      try {
        final bytes = await file.readAsBytes();
        return await _parseIndex(bytes);
      } on Object {
        _indexes.remove(system);
        rethrow;
      }
    }();
  }

  Future<DatInfo> _run(String system, Future<DatInfo> Function() job) async {
    _busy.add(system);
    notifyListeners();
    try {
      return await job();
    } finally {
      _busy.remove(system);
      notifyListeners();
    }
  }

  static Future<DatIndex> _parseIndex(List<int> bytes) =>
      Isolate.run(() => DatIndex(DatFile.parseBytes(bytes)));

  /// Parses [bytes] in an isolate: header name, version and game count.
  static Future<(String, String?, int)> _check(List<int> bytes) =>
      Isolate.run(() {
        final dat = DatFile.parseBytes(bytes);
        return (dat.name, dat.version, dat.games.length);
      });

  Future<DatInfo> _install(List<int> bytes, DatInfo info) async {
    await Directory(_dir).create(recursive: true);
    await _writeAtomic(_datFile(info.system), bytes);
    await _writeAtomic(
      _jsonFile(info.system),
      utf8.encode(jsonEncode(info.toJson())),
    );
    _infos[info.system] = info;
    _indexes.remove(info.system);
    return info;
  }

  static Future<void> _writeAtomic(File file, List<int> bytes) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }
}
