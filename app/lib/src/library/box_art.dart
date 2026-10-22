// SPDX-License-Identifier: GPL-3.0-or-later
// Box art: CRC or title lookup in the bundled index, on-demand download and
// cache.
// Spec: docs/specs/box-art.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'database.dart';
import 'romhacks.dart';

/// Thumbnail-server folder per system (also the DAT names in the index).
const boxArtSystems = {
  'nes': 'Nintendo - Nintendo Entertainment System',
  'snes': 'Nintendo - Super Nintendo Entertainment System',
  'gb': 'Nintendo - Game Boy',
  'gbc': 'Nintendo - Game Boy Color',
  'gba': 'Nintendo - Game Boy Advance',
  'nds': 'Nintendo - Nintendo DS',
  'n64': 'Nintendo - Nintendo 64',
  'genesis': 'Sega - Mega Drive - Genesis',
  'psx': 'Sony - PlayStation',
  'psp': 'Sony - PlayStation Portable',
  'saturn': 'Sega - Saturn',
  'dreamcast': 'Sega - Dreamcast',
  'gamecube': 'Nintendo - GameCube',
  'wii': 'Nintendo - Wii',
  'ps2': 'Sony - PlayStation 2',
};

const thumbnailHost = 'https://thumbnails.libretro.com';

/// The libretro thumbnail URL for a game [name] (box art).
/// The server's file names replace `&*/:\`<>?\\|"` with `_`.
Uri boxArtUrl(String system, String name) {
  final file = name.replaceAll(RegExp(r'[&*/:`<>?\\|"]'), '_');
  return Uri.parse(thumbnailHost).replace(
    pathSegments: [boxArtSystems[system]!, 'Named_Boxarts', '$file.png'],
  );
}

/// system → CRC-32 (lower-case hex) → game name, from the bundled index.
///
/// Also indexes names by [titleKey] and disc serial so games whose CRC is
/// unknown (hacks, re-dumps, `.chd`/`.cso` discs, obscure releases) can still
/// be matched by file name (box-art.md, "Name fallback").
class BoxArtIndex {
  BoxArtIndex(this._names, [Map<String, Map<String, String>>? serials])
    : _serials = serials ?? const {} {
    for (final MapEntry(key: system, value: byCrc) in _names.entries) {
      final byTitle = _titles[system] = {};
      for (final name in byCrc.values) {
        final names = byTitle.putIfAbsent(titleKey(name), () => []);
        if (!names.contains(name)) names.add(name);
      }
    }
    // `Pokemon - Emerald Version` also answers to `pokemon emerald`, so
    // `Pokemon Emerald Seaglass` finds its base game by parent title. A real
    // title with that key keeps it.
    for (final byTitle in _titles.values) {
      final aliases = <String, List<String>>{};
      for (final MapEntry(:key, :value) in byTitle.entries) {
        final m = RegExp(r'^(.+ .+) (version|edition)$').firstMatch(key);
        if (m != null && !byTitle.containsKey(m[1])) {
          aliases.putIfAbsent(m[1]!, () => []).addAll(value);
        }
      }
      byTitle.addAll(aliases);
    }
  }

  final Map<String, Map<String, String>> _names;

  /// system → serial (upper case, no separator: `ULUS10018`) → game name.
  final Map<String, Map<String, String>> _serials;
  final _titles = <String, Map<String, List<String>>>{};

  /// Lines are `system, crc, name[, serial]`.
  static BoxArtIndex parse(String tsv) {
    final names = <String, Map<String, String>>{};
    final serials = <String, Map<String, String>>{};
    for (final line in const LineSplitter().convert(tsv)) {
      final parts = line.split('\t');
      if (parts.length != 3 && parts.length != 4) continue;
      names.putIfAbsent(parts[0], () => {})[parts[1]] = parts[2];
      if (parts.length == 4) {
        serials.putIfAbsent(parts[0], () => {})[_serialKey(parts[3])] ??=
            parts[2];
      }
    }
    return BoxArtIndex(names, serials);
  }

  /// Loads `assets/boxart/index.tsv.gz`.
  static Future<BoxArtIndex> load([AssetBundle? bundle]) async {
    final data = await (bundle ?? rootBundle).load(
      'assets/boxart/index.tsv.gz',
    );
    final bytes = gzip.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    return parse(utf8.decode(bytes));
  }

  String? nameFor(String system, String crc32) =>
      _names[system]?[crc32.toLowerCase()];

  /// The best-matching game name for a ROM file called [fileName], or null.
  String? nameForFile(String system, String fileName, {String? title}) {
    final names = candidatesForFile(system, fileName, title: title);
    return names.isEmpty ? null : names.first;
  }

  /// Game names that may be the cover for a ROM file called [fileName]
  /// (and library [title], when the player renamed it), best first. The
  /// cache tries them in order, so a cover missing on the server for one
  /// region falls back to another.
  ///
  /// Tried in order, first hit wins: a disc serial in the name
  /// (`[ULUS-10018]`); a known romhack's base game ([romhackFor]); the
  /// exact [titleKey]; the key without hack and
  /// version noise ([hackKey]); the parent title (before ` - ` or `:`, then
  /// dropping trailing words while at least half the key remains); and a
  /// fuzzy match (bigram similarity at least [fuzzyThreshold]).
  List<String> candidatesForFile(
    String system,
    String fileName, {
    String? title,
  }) {
    final byTitle = _titles[system];
    if (byTitle == null) return const [];
    final queries = [fileName, ?title];
    for (final q in queries) {
      for (final m in _serialPattern.allMatches(q.toUpperCase())) {
        final name = _serials[system]?['${m[1]}${m[2]}${m[3]}'];
        if (name != null) {
          final rest = _ranked(byTitle[titleKey(name)] ?? [name], fileName);
          return [name, ...rest.where((n) => n != name)];
        }
      }
    }
    for (final q in queries) {
      final hack = romhackFor(system, q);
      if (hack == null) continue;
      final names = byTitle[titleKey(hack.base)];
      if (names != null) return _ranked(names, fileName);
    }
    for (final keyOf in <String? Function(String)>[
      titleKey,
      hackKey,
      (q) => _parentKey(byTitle, q),
    ]) {
      for (final q in queries) {
        final key = keyOf(q);
        if (key == null || key.isEmpty) continue;
        final names = byTitle[key];
        if (names != null) return _ranked(names, fileName);
      }
    }
    for (final q in queries) {
      final key = hackKey(q);
      if (key.length < 4) continue;
      final best = _fuzzy(byTitle.keys, key);
      if (best != null) return _ranked(byTitle[best]!, fileName);
    }
    return const [];
  }

  /// Minimum Dice similarity of title bigrams for a fuzzy match.
  static const fuzzyThreshold = 0.8;

  String? _parentKey(Map<String, List<String>> byTitle, String name) {
    final full = hackKey(name);
    final base = name.replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ');
    final cut = base.split(RegExp(r' - |: ')).first;
    if (cut != base) {
      // A subtitle cut names the base game outright; only two words needed.
      final k = hackKey(cut);
      if (k.contains(' ') && byTitle.containsKey(k)) return k;
    }
    final words = full.split(' ');
    for (var n = words.length - 1; n >= 1; n--) {
      final k = words.take(n).join(' ');
      if (_titlesHas(byTitle, k, full)) return k;
    }
    return null;
  }

  // A parent key must keep at least half of the full key and two words,
  // so "pokemon radical red" doesn't collapse to any "pokemon" game.
  // Only the game's own system counts, or a key from another system would
  // stop the search before shorter keys of this one are tried.
  static bool _titlesHas(
    Map<String, List<String>> byTitle,
    String key,
    String full,
  ) =>
      key.contains(' ') &&
      key.length * 2 >= full.length &&
      byTitle.containsKey(key);

  /// Orders [names] for a file called [fileName]: the region named in the
  /// file's own tags, then USA, World, Europe, Japan; final releases over
  /// betas, demos and revisions.
  List<String> _ranked(List<String> names, String fileName) {
    final wanted = _tags(fileName).where(_regionRank.containsKey).toSet();
    int score(String name) {
      final tags = _tags(name);
      var s = 0;
      for (final t in tags) {
        if (wanted.contains(t)) s -= 100;
        if (_regionRank[t] case final r?) s += r;
        if (_unwanted.hasMatch(t)) s += 20;
      }
      return s * 1000 + name.length;
    }

    return [...names]..sort((a, b) => score(a).compareTo(score(b)));
  }
}

String? _fuzzy(Iterable<String> keys, String key) {
  final want = _bigrams(key);
  String? best;
  var bestScore = BoxArtIndex.fuzzyThreshold;
  for (final k in keys) {
    // Cheap length filter: Dice can't reach the threshold past this.
    if ((k.length - key.length).abs() * 2 > key.length) continue;
    final have = _bigrams(k);
    var common = 0;
    final pool = [...have];
    for (final b in want) {
      if (pool.remove(b)) common++;
    }
    final score = 2 * common / (want.length + have.length);
    if (score > bestScore) {
      bestScore = score;
      best = k;
    }
  }
  return best;
}

List<String> _bigrams(String s) {
  final t = s.replaceAll(' ', '');
  return [for (var i = 0; i + 1 < t.length; i++) t.substring(i, i + 2)];
}

/// PSP/PS1 style serials: `ULUS-10018`, `SLUS_005.94`, `ULUS10018`.
final _serialPattern = RegExp(
  r'(?<![A-Z0-9])([A-Z]{4})[-_ ]?(\d{3})\.?(\d{2})(?!\d)',
);

String _serialKey(String serial) {
  final m = _serialPattern.firstMatch(serial.toUpperCase());
  return m == null ? serial.toUpperCase() : '${m[1]}${m[2]}${m[3]}';
}

/// [titleKey] without romhack and version noise: `v1.2`, `rev a`, `hack`,
/// `kaizo`, `translated`, `patched`, `(by Author)` and `... by Author`.
String hackKey(String name) {
  final base = name.replaceFirst(
    RegExp(
      r'\s+(by|hack by|translation by)\s+[^()\[\]]*$',
      caseSensitive: false,
    ),
    '',
  );
  final words = titleKey(base).split(' ');
  const noise = {
    'hack',
    'romhack',
    'kaizo',
    'translated',
    'translation',
    'patched',
    'patch',
    'fixed',
    'fix',
    'improved',
    'eng',
    'english',
    'final',
    'rev',
  };
  final out = <String>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (noise.contains(w)) continue;
    // version numbers: v1, v1 2 (from "v1.2"), 1 0 after a dropped "v"
    if (RegExp(r'^v\d+$').hasMatch(w)) {
      while (i + 1 < words.length && RegExp(r'^\d+$').hasMatch(words[i + 1])) {
        i++;
      }
      continue;
    }
    out.add(w);
  }
  return out.join(' ');
}

const _regionRank = {'usa': 0, 'world': 1, 'europe': 2, 'japan': 3};
final _unwanted = RegExp(
  r'^(beta|proto|demo|sample|kiosk|rev|unl|pirate|aftermarket|virtual)',
);

/// Lower-case tag words in a name: `(USA, Europe) (Rev 1)` → usa, europe,
/// rev 1.
Iterable<String> _tags(String name) =>
    RegExp(r'[(\[]([^)\]]*)[)\]]')
        .allMatches(name)
        .expand((m) => m.group(1)!.split(','))
        .map((t) => t.trim().toLowerCase());

/// A name reduced for matching: no extension, tags, articles, punctuation or
/// case. `Legend of Zelda, The - A Link to the Past (USA).sfc` and
/// `the_legend_of_zelda_a_link_to_the_past.smc` give the same key.
String titleKey(String name) {
  var s = _foldAccents(name.toLowerCase());
  s = s.replaceFirst(RegExp(r'\.(zip|7z|[a-z0-9]{1,4})$'), '');
  s = s
      .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[_.]'), ' ');
  // "Zelda, The - X" → "The Zelda - X"
  s = s.replaceAllMapped(
    RegExp(r'^([^-]*?), (the|a|an)\b'),
    (m) => '${m[2]} ${m[1]}',
  );
  s = s.replaceAll(RegExp(r"[^a-z0-9 ]"), ' ');
  final words = s.split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isNotEmpty && const {'the', 'a', 'an'}.contains(words.first)) {
    words.removeAt(0);
  }
  return words.join(' ');
}

const _accents = {
  'a': 'àáâãäåā',
  'c': 'ç',
  'e': 'èéêëē',
  'i': 'ìíîïī',
  'n': 'ñ',
  'o': 'òóôõöøō',
  'u': 'ùúûüū',
  'y': 'ýÿ',
};

/// `pokémon` → `pokemon`, so accented names match their plain spelling.
String _foldAccents(String s) {
  if (!s.contains(RegExp(r'[^\x00-\x7f]'))) return s;
  final out = StringBuffer();
  for (final c in s.split('')) {
    out.write(
      _accents.entries
              .where((e) => e.value.contains(c))
              .map((e) => e.key)
              .firstOrNull ??
          c,
    );
  }
  return out.toString();
}

/// Downloads a URL's bytes; null when the server has no such file. Throws
/// when the download failed (offline, timeout, server error), so the cache
/// tries again later instead of recording a miss. Injectable for tests.
typedef Fetch = Future<List<int>?> Function(Uri url);

Future<List<int>?> httpFetch(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(url);
    final res = await req.close();
    if (res.statusCode == 404 || res.statusCode == 410) {
      await res.drain<void>();
      return null;
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

/// Finds, downloads and caches covers under `<dataDir>/art/`.
///
/// A miss (no index entry or no image on the server) is remembered for
/// [retryAfter] with an empty `.none` marker, so the grid doesn't refetch.
/// A failed download (offline) records nothing on disk and is retried the
/// next time the app starts.
class BoxArtCache {
  BoxArtCache(
    this.dataDir, {
    required this.loadIndex,
    this.fetch = httpFetch,
    this.clock = DateTime.now,
    this.retryAfter = const Duration(days: 7),
  });

  final String dataDir;

  /// Loads the CRC index (once, on first use).
  final Future<BoxArtIndex> Function() loadIndex;
  final Fetch fetch;
  final DateTime Function() clock;
  final Duration retryAfter;

  Future<BoxArtIndex>? _loaded;
  final _inFlight = <String, Future<File?>>{};

  /// Written into `.none` markers; bump when matching improves so earlier
  /// misses are retried.
  static const matcherVersion = 'm3';

  /// Games whose download failed this run; not retried until restart.
  final _failed = <String>{};

  String get _dir => p.join(dataDir, 'art');

  /// Bumped when a cover changes on disk outside a download, so the library
  /// redraws it.
  final revision = ValueNotifier<int>(0);

  /// Tells the library a cover changed ([revision]).
  void coverChanged() => revision.value++;

  /// The file shown for [game] ([originalCoverFor]).
  Future<File?> coverFor(Game game) => originalCoverFor(game);

  /// [game]'s own cover: its custom art, else the cached or freshly
  /// downloaded cover, else null.
  Future<File?> originalCoverFor(Game game) {
    final custom = game.customArtPath;
    if (custom != null) {
      final f = File(custom);
      if (f.existsSync()) return Future.value(f);
    }
    // A PICO-8 `.p8.png` cart is its own label art.
    if (game.system == 'pico8' && game.path.toLowerCase().endsWith('.png')) {
      final f = File(game.path);
      return Future.value(f.existsSync() ? f : null);
    }
    return _inFlight.putIfAbsent(game.sha1, () async {
      try {
        return await _download(game);
      } finally {
        _inFlight.remove(game.sha1);
      }
    });
  }

  /// Starts fetching the covers of newly imported [games] in the background,
  /// so they are ready when the grid shows them.
  void prefetch(Iterable<Game> games) {
    for (final g in games) {
      unawaited(coverFor(g).then((_) {}, onError: (Object _) {}));
    }
  }

  Future<File?> _download(Game game) async {
    final file = File(p.join(_dir, '${game.sha1}.png'));
    if (await file.exists()) return file;
    if (!boxArtSystems.containsKey(game.system) ||
        _failed.contains(game.sha1)) {
      return null;
    }
    final none = File(p.join(_dir, '${game.sha1}.none'));
    // Markers from an older matcher are ignored, so games it missed are
    // looked up again with the current one.
    if (await none.exists() &&
        await none.readAsString() == matcherVersion &&
        clock().difference(await none.lastModified()) < retryAfter) {
      return null;
    }
    final index = await (_loaded ??= loadIndex());
    final byCrc = index.nameFor(game.system, game.crc32);
    // A romhack's own cover first, then its base game's.
    final queries = [game.fileName, game.title];
    final hack = byCrc != null
        ? null
        : queries.map((q) => romhackFor(game.system, q)).nonNulls.firstOrNull;
    final ownArt = hack?.art ?? const <String>[];
    final names = <String>{
      ?byCrc,
      ...ownArt,
      ...index
          .candidatesForFile(game.system, game.fileName, title: game.title)
          .take(4),
    };
    List<int>? bytes;
    String? found;
    try {
      for (final name in names) {
        bytes = await fetch(boxArtUrl(game.system, name));
        if (bytes != null && bytes.isNotEmpty) {
          found = name;
          break;
        }
      }
    } on Object {
      _failed.add(game.sha1);
      return null;
    }
    await Directory(_dir).create(recursive: true);
    if (bytes == null || bytes.isEmpty) {
      await none.writeAsString(matcherVersion);
      return null;
    }
    // The base game's cover stands in for a hack: the card says so.
    final badge = File(p.join(_dir, '${game.sha1}.hack'));
    if (byCrc == null &&
        !ownArt.contains(found) &&
        (hack != null || queries.any(looksLikeHack))) {
      await badge.writeAsString('');
    } else if (await badge.exists()) {
      await badge.delete();
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return file;
  }

  /// Whether [game]'s cached cover is its base game's, standing in for a
  /// romhack with no art of its own (the card shows a HACK badge).
  Future<bool> isHackStandIn(Game game) async {
    if (game.customArtPath != null) return false;
    return File(p.join(_dir, '${game.sha1}.hack')).exists();
  }

  /// Copies [image] in as [game]'s custom cover; returns the stored path.
  Future<String> storeCustom(Game game, File image) async {
    await Directory(_dir).create(recursive: true);
    final ext = p.extension(image.path).toLowerCase();
    final out = p.join(
      _dir,
      '${game.sha1}.custom${ext.isEmpty ? '.png' : ext}',
    );
    await image.copy(out);
    return out;
  }

  /// Removes [game]'s cached and custom covers (game deleted).
  Future<void> forget(Game game) async {
    final dir = Directory(_dir);
    if (!await dir.exists()) return;
    await for (final f in dir.list()) {
      if (p.basename(f.path).startsWith(game.sha1)) await f.delete();
    }
  }
}
