// SPDX-License-Identifier: GPL-3.0-or-later
// Cheat database: libretro-database `cht/` lookup, download, cache, parsing
// and the "popular" ranking. Spec: docs/specs/cheats.md (Cheat database)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../library/box_art.dart';
import '../library/database.dart';
import 'cheat_codes.dart';

/// libretro-database commit the bundled index was built from.
const cheatDbCommit = '12c21cf79f1e20eff6ac68b80875816c717d0a7a';

/// `cht/` folder per system.
const cheatDbSystems = {
  'nes': 'Nintendo - Nintendo Entertainment System',
  'snes': 'Nintendo - Super Nintendo Entertainment System',
  'gb': 'Nintendo - Game Boy',
  'gbc': 'Nintendo - Game Boy Color',
  'gba': 'Nintendo - Game Boy Advance',
  'n64': 'Nintendo - Nintendo 64',
  'nds': 'Nintendo - Nintendo DS',
  'psx': 'Sony - PlayStation',
  'psp': 'Sony - PlayStation Portable',
};

/// The raw URL of a cheat [file] (name without `.cht`) at the pinned commit.
Uri cheatFileUrl(String system, String file) => Uri(
  scheme: 'https',
  host: 'raw.githubusercontent.com',
  pathSegments: [
    'libretro',
    'libretro-database',
    cheatDbCommit,
    'cht',
    cheatDbSystems[system]!,
    '$file.cht',
  ],
);

/// Cheat-device suffixes in file names, e.g. `Game (USA) (Game Genie)`.
const _devices = {
  'game genie',
  'action replay',
  'pro action replay',
  'action replay max',
  'gameshark',
  'game shark',
  'code breaker',
  'codebreaker',
  'game buster',
  'xploder',
  'gold finger',
  'goldfinger',
  'cheats',
};

final _lastTag = RegExp(r'\s*\(([^()]*)\)$');

/// The file's cheat device ("Game Genie"), or null when the name has none.
String? deviceOf(String file) {
  final m = _lastTag.firstMatch(file);
  if (m == null) return null;
  return _devices.contains(m.group(1)!.toLowerCase()) ? m.group(1) : null;
}

/// [file] without its device suffix.
String baseOf(String file) =>
    deviceOf(file) == null ? file : file.replaceFirst(_lastTag, '');

/// Name without tags, lower-cased, letters and digits only.
String looseKey(String name) => name
    .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), '')
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]'), '');

const _regionAlias = {'us': 'usa', 'eu': 'europe', 'jp': 'japan'};

/// Region and other tags of a name, lower-cased, aliases folded.
Set<String> _tags(String name) => {
  for (final m in RegExp(r'[(\[]([^)\]]*)[)\]]').allMatches(name))
    for (final t in m.group(1)!.split(','))
      if (t.trim().isNotEmpty)
        _regionAlias[t.trim().toLowerCase()] ?? t.trim().toLowerCase(),
};

/// system → cheat file names (without `.cht`), from the bundled index.
class CheatDbIndex {
  CheatDbIndex(this._files);

  final Map<String, List<String>> _files;

  static CheatDbIndex parse(String tsv) {
    final files = <String, List<String>>{};
    for (final line in const LineSplitter().convert(tsv)) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      files
          .putIfAbsent(line.substring(0, tab), () => [])
          .add(line.substring(tab + 1));
    }
    return CheatDbIndex(files);
  }

  /// Loads `assets/cheats/index.tsv.gz`.
  static Future<CheatDbIndex> load([AssetBundle? bundle]) async {
    final data = await (bundle ?? rootBundle).load(
      'assets/cheats/index.tsv.gz',
    );
    final bytes = gzip.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    return parse(utf8.decode(bytes));
  }

  /// The cheat files for a game called [name] (No-Intro name or file name
  /// without extension), sorted by name. Empty when nothing matches.
  List<String> match(String system, String name) {
    final files = _files[system];
    if (files == null) return const [];
    // Same title, then the bases sharing most tags (region) with the game;
    // an exact name always shares all of them.
    final key = looseKey(name);
    if (key.isEmpty) return const [];
    final loose = [
      for (final f in files)
        if (looseKey(f) == key) f,
    ];
    if (loose.isEmpty) return const [];
    final want = _tags(name);
    int score(String f) => _tags(baseOf(f)).intersection(want).length;
    final best = loose.map(score).reduce((a, b) => a > b ? a : b);
    return [
      for (final f in loose)
        if (score(f) == best) f,
    ]..sort();
  }
}

/// One cheat from the database, ready to store.
class DbCheat {
  const DbCheat({
    required this.name,
    required this.code,
    required this.format,
    this.score = 0,
    this.master = false,
  });

  final String name;

  /// Stored form: one code per line (see [coreCode]).
  final String code;
  final String format;

  /// Popularity score (0 = never popular).
  final int score;

  /// A master/enabler code the other cheats of its file need.
  final bool master;

  @override
  String toString() => 'DbCheat($name, $format, $score)';
}

final _master = RegExp(
  r'must be on|master code|enable code|enabler|\(m\)',
  caseSensitive: false,
);

const _inf = r'(infinite|inf\.?|unlimited|unlim\.?|max(imum)?|full|never die)';

/// Popularity categories, first match wins (spec table).
final _categories = <(int, RegExp)>[
  (100, RegExp('$_inf.*\\b(health|hp|energy|life)\\b', caseSensitive: false)),
  (
    95,
    RegExp(r'invincib|invulnerab|god ?mode|no damage', caseSensitive: false),
  ),
  (90, RegExp('$_inf.*\\b(lives|men)\\b', caseSensitive: false)),
  (
    85,
    RegExp(
      '$_inf.*\\b(money|gold|coins?|cash|rupees?|gil|zenny|funds)\\b',
      caseSensitive: false,
    ),
  ),
  (
    80,
    RegExp(
      '$_inf.*\\b(ammo|bullets|magic|mp|bombs|weapons?|missiles)\\b',
      caseSensitive: false,
    ),
  ),
  (
    75,
    RegExp(
      r'all (items|weapons)|have all|unlock(ed)? all|all levels|'
      r'(level|stage) select',
      caseSensitive: false,
    ),
  ),
  (
    70,
    RegExp(r'max(imum)? (stats|level)|\bexp(erience)?\b', caseSensitive: false),
  ),
  (
    60,
    RegExp(
      r'(infinite|stop|freeze|unlimited) time|timer',
      caseSensitive: false,
    ),
  ),
  (
    55,
    RegExp(r'moon ?jump|super jump|walk through walls', caseSensitive: false),
  ),
  (50, RegExp(r'(one|1)[ -]hit kill', caseSensitive: false)),
];

final _player2 = RegExp(r'\bP2\b|player 2|\b2P\b', caseSensitive: false);

/// The popularity score of a cheat [description] (spec: Popular).
int popularityScore(String description) {
  if (_master.hasMatch(description)) return 0;
  for (final (score, re) in _categories) {
    if (re.hasMatch(description)) {
      return _player2.hasMatch(description) ? score - 10 : score;
    }
  }
  return 0;
}

/// The [count] most popular of [cheats] (ties keep list order).
List<DbCheat> popular(List<DbCheat> cheats, {int count = 5}) {
  final ranked = [
    for (final c in cheats)
      if (c.score > 0) c,
  ];
  // List.sort isn't stable; sort by (score, position).
  final pos = {for (final (i, c) in cheats.indexed) c: i};
  ranked.sort((a, b) {
    final s = b.score.compareTo(a.score);
    return s != 0 ? s : pos[a]!.compareTo(pos[b]!);
  });
  return ranked.take(count).toList();
}

final _entry = RegExp(r'^cheat(\d+)_(desc|code)\s*=\s*"?(.*?)"?\s*$');

/// Parses a `.cht` file's [text] for [system]. [device] labels codes the
/// validator doesn't know (the file's device, else "Database").
List<DbCheat> parseCht(String system, String text, {String? device}) {
  final desc = <int, String>{};
  final code = <int, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final m = _entry.firstMatch(line.trim());
    if (m == null) continue;
    final i = int.parse(m.group(1)!);
    (m.group(2) == 'desc' ? desc : code)[i] = m.group(3)!.trim();
  }
  final out = <DbCheat>[];
  for (final i in code.keys.toList()..sort()) {
    final raw = code[i]!;
    if (raw.isEmpty || raw.contains('?')) continue;
    final lines =
        (system == 'psp'
                ? raw.split(RegExp(r'(?=_L\s)')).expand((l) => l.split('+'))
                : raw.split('+'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
    if (lines.isEmpty) continue;
    final name = (desc[i]?.isNotEmpty ?? false) ? desc[i]! : lines.first;
    final parsed = parseCheat(system, lines.join('\n'));
    out.add(
      DbCheat(
        name: name,
        code: parsed?.stored ?? lines.join('\n'),
        format: parsed?.format ?? device ?? 'Database',
        score: popularityScore(name),
        master: _master.hasMatch(name),
      ),
    );
  }
  return out;
}

/// What the browser shows for a game.
class CheatLookup {
  CheatLookup(this.cheats, [Map<DbCheat, List<DbCheat>>? masters])
    : _masters = masters ?? const {};

  /// Every cheat of the matched files, in file order.
  final List<DbCheat> cheats;
  final Map<DbCheat, List<DbCheat>> _masters;

  /// The master codes [c] needs: those of its file (none for a master).
  List<DbCheat> mastersOf(DbCheat c) => _masters[c] ?? const [];

  late final List<DbCheat> popularCheats = popular(cheats);
}

/// Thrown when a cheat file couldn't be downloaded.
class CheatDownloadException implements Exception {
  const CheatDownloadException(this.file);

  final String file;

  @override
  String toString() => "Couldn't download cheats ($file)";
}

/// Finds, downloads and caches a game's cheats under `<dataDir>/cheats/`.
class CheatDatabase {
  CheatDatabase(
    this.dataDir, {
    required this.loadIndex,
    required this.loadNames,
    this.fetch = httpFetch,
  });

  final String dataDir;

  /// Loads the cheat file index (once).
  final Future<CheatDbIndex> Function() loadIndex;

  /// Loads the CRC → No-Intro name index (once).
  final Future<BoxArtIndex> Function() loadNames;
  final Fetch fetch;

  Future<CheatDbIndex>? _index;
  Future<BoxArtIndex>? _names;

  /// The cheat files matching [game] (no network).
  Future<List<String>> filesFor(Game game) async {
    if (!cheatDbSystems.containsKey(game.system)) return const [];
    final index = await (_index ??= loadIndex());
    String? name;
    try {
      final names = await (_names ??= loadNames());
      name =
          names.nameFor(game.system, game.crc32) ??
          names.nameForFile(game.system, game.fileName);
    } on Object {
      name = null;
    }
    name ??= _stripExtension(game.fileName);
    return index.match(game.system, name);
  }

  /// All database cheats for [game]. Throws [CheatDownloadException] when a
  /// file isn't cached and can't be downloaded.
  Future<CheatLookup> cheatsFor(Game game) async {
    final cheats = <DbCheat>[];
    final mastersOf = <DbCheat, List<DbCheat>>{};
    for (final file in await filesFor(game)) {
      final text = await _read(game.system, file);
      final parsed = parseCht(game.system, text, device: deviceOf(file));
      final masters = [
        for (final c in parsed)
          if (c.master) c,
      ];
      for (final c in parsed) {
        if (!c.master && masters.isNotEmpty) mastersOf[c] = masters;
      }
      cheats.addAll(parsed);
    }
    return CheatLookup(cheats, mastersOf);
  }

  Future<String> _read(String system, String file) async {
    final f = File(p.join(dataDir, 'cheats', system, '$file.cht'));
    if (await f.exists()) return f.readAsString();
    final bytes = await fetch(cheatFileUrl(system, file));
    if (bytes == null) throw CheatDownloadException(file);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
    return utf8.decode(bytes, allowMalformed: true);
  }
}

String _stripExtension(String fileName) {
  final base = p.basename(fileName);
  // `.p8.png` and the like don't occur for cheat systems; one extension.
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}
