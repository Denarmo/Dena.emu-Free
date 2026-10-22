// SPDX-License-Identifier: GPL-3.0-or-later
// Media art: the label on a cartridge, the face of a disc or UMD, fetched on
// demand and cached next to the covers.
// Spec: docs/specs/launch-animation.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'box_art.dart';
import 'database.dart';

/// What a system's games come on.
enum MediaKind { cartridge, disc, umd, pico8Cart }

/// The media a game of [system] comes on; cartridges for anything unknown.
MediaKind mediaKindFor(String system) => switch (system) {
  'psx' ||
  'ps2' ||
  'saturn' ||
  'dreamcast' ||
  'segacd' ||
  'gamecube' ||
  'wii' => MediaKind.disc,
  'psp' => MediaKind.umd,
  'pico8' => MediaKind.pico8Cart,
  _ => MediaKind.cartridge,
};

/// ScreenScraper system ids (public API v2 `systemesListe`).
const screenScraperSystems = {
  'genesis': 1,
  'nes': 3,
  'snes': 4,
  'gb': 9,
  'gbc': 10,
  'gba': 12,
  'n64': 14,
  'nds': 15,
  '3ds': 17,
  'saturn': 22,
  'dreamcast': 23,
  'gamecube': 13,
  'wii': 16,
  'psx': 57,
  'ps2': 58,
  'psp': 61,
};

/// Finds genuine media art for a game: the image URL, or null when the
/// source knows the game but has no scan. Throws when the lookup failed
/// (offline, quota, server error) so the cache retries later.
abstract interface class MediaArtSource {
  Future<Uri?> find(Game game, {String? name});
}

/// Media scans from ScreenScraper (screenscraper.fr). Cartridges use the flat
/// label texture (`support-texture`), discs and UMDs the face scan
/// (`support-2D`). Needs developer credentials, passed at build time with
/// `--dart-define=DENA_SCREENSCRAPER_DEVID=… DENA_SCREENSCRAPER_DEVPASSWORD=…`.
class ScreenScraperSource implements MediaArtSource {
  ScreenScraperSource({
    required this.devId,
    required this.devPassword,
    this.fetch = httpFetch,
  });

  /// The build's credentials, or null when the build has none.
  static ScreenScraperSource? fromEnvironment() {
    const id = String.fromEnvironment('DENA_SCREENSCRAPER_DEVID');
    const pw = String.fromEnvironment('DENA_SCREENSCRAPER_DEVPASSWORD');
    if (id.isEmpty || pw.isEmpty) return null;
    return ScreenScraperSource(devId: id, devPassword: pw);
  }

  final String devId, devPassword;
  final Fetch fetch;

  /// One request at a time: the free API allows a single thread.
  Future<void> _queue = Future.value();

  static const host = 'https://api.screenscraper.fr/api2/jeuInfos.php';

  Uri lookupUrl(Game game, {String? name}) => Uri.parse(host).replace(
    queryParameters: {
      'devid': devId,
      'devpassword': devPassword,
      'softname': 'dena-emu',
      'output': 'json',
      'romtype': 'rom',
      'systemeid': '${screenScraperSystems[game.system]}',
      'crc': game.crc32.toUpperCase(),
      'sha1': game.sha1.toUpperCase(),
      'romnom': name ?? game.fileName,
    },
  );

  @override
  Future<Uri?> find(Game game, {String? name}) {
    if (!screenScraperSystems.containsKey(game.system)) {
      return Future.value(null);
    }
    final done = Completer<Uri?>();
    _queue = _queue.then((_) async {
      try {
        final bytes = await fetch(lookupUrl(game, name: name));
        done.complete(
          bytes == null ? null : pickMedia(utf8.decode(bytes), game),
        );
      } on Object catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  /// The best media URL in a `jeuInfos` JSON reply for [game]: the right
  /// type for its media kind, in the region its file name asks for, else
  /// USA, World, Europe, Japan, any.
  static Uri? pickMedia(String json, Game game) {
    final Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      return null; // "Erreur : Rom/Iso/Dossier non trouvée !" is plain text.
    }
    if (data case {
      'response': {'jeu': {'medias': final List<Object?> media}},
    }) {
      final want = mediaKindFor(game.system) == MediaKind.cartridge
          ? const ['support-texture', 'support-2D']
          : const ['support-2D', 'support-texture'];
      final regions = [..._fileRegions(game.fileName), 'us', 'wor', 'eu', 'jp'];
      for (final type in want) {
        final ofType = [
          for (final m in media)
            if (m case {'type': final String t, 'url': final String url}
                when t == type && url.isNotEmpty)
              m as Map,
        ];
        if (ofType.isEmpty) continue;
        for (final r in regions) {
          for (final m in ofType) {
            if (m['region'] == r) return Uri.tryParse(m['url'] as String);
          }
        }
        return Uri.tryParse(ofType.first['url'] as String);
      }
    }
    return null;
  }
}

/// ScreenScraper region codes named in a No-Intro file name's tags.
List<String> _fileRegions(String fileName) {
  const codes = {
    'usa': 'us',
    'world': 'wor',
    'europe': 'eu',
    'japan': 'jp',
    'france': 'fr',
    'germany': 'de',
    'spain': 'sp',
    'italy': 'it',
    'korea': 'kr',
  };
  return [
    for (final m in RegExp(r'\(([^)]*)\)').allMatches(fileName))
      for (final t in m[1]!.split(',')) ?codes[t.trim().toLowerCase()],
  ];
}

/// Downloads and caches media art under `<dataDir>/art/<sha1>.media.png`,
/// alongside the covers ([BoxArtCache.forget] removes both).
///
/// Order: the player's custom media art, the cached file, then [source].
/// A miss is remembered for [retryAfter] with a `.media.none` marker; a
/// failed lookup records nothing and is retried after a restart. With no
/// source, or no art, the media widgets dress the cover instead.
class MediaArtCache {
  MediaArtCache(
    this.dataDir, {
    this.source,
    this.index,
    this.fetch = httpFetch,
    this.clock = DateTime.now,
    this.retryAfter = const Duration(days: 7),
  });

  final String dataDir;
  final MediaArtSource? source;

  /// Names games by CRC for the lookup; the file name is used without it.
  final Future<BoxArtIndex> Function()? index;
  final Fetch fetch;
  final DateTime Function() clock;
  final Duration retryAfter;

  Future<BoxArtIndex>? _loaded;
  final _inFlight = <String, Future<File?>>{};
  final _failed = <String>{};

  String get _dir => p.join(dataDir, 'art');

  File _file(Game g) => File(p.join(_dir, '${g.sha1}.media.png'));
  File _none(Game g) => File(p.join(_dir, '${g.sha1}.media.none'));
  File _custom(Game g) => File(p.join(_dir, '${g.sha1}.media.custom.png'));

  /// [game]'s media art, or null (use the cover).
  Future<File?> mediaFor(Game game) async {
    final custom = _custom(game);
    if (await custom.exists()) return custom;
    // A PICO-8 cart's label is the `.p8.png` itself.
    if (game.system == 'pico8') {
      final f = File(game.path);
      return game.path.toLowerCase().endsWith('.png') && await f.exists()
          ? f
          : null;
    }
    return _inFlight.putIfAbsent(game.sha1, () async {
      try {
        return await _download(game);
      } finally {
        _inFlight.remove(game.sha1);
      }
    });
  }

  /// The cached file only, without a lookup; for the first frame of the
  /// launch animation.
  File? cachedFor(Game game) {
    for (final f in [_custom(game), _file(game)]) {
      if (f.existsSync()) return f;
    }
    return null;
  }

  Future<File?> _download(Game game) async {
    final file = _file(game);
    if (await file.exists()) return file;
    final src = source;
    if (src == null || _failed.contains(game.sha1)) return null;
    final none = _none(game);
    if (await none.exists() &&
        clock().difference(await none.lastModified()) < retryAfter) {
      return null;
    }
    List<int>? bytes;
    try {
      final names = index == null ? null : await (_loaded ??= index!());
      final name = names?.nameFor(game.system, game.crc32);
      final url = await src.find(game, name: name);
      if (url != null) bytes = await fetch(url);
    } on Object {
      _failed.add(game.sha1);
      return null;
    }
    await Directory(_dir).create(recursive: true);
    if (bytes == null || bytes.isEmpty) {
      await none.writeAsString('');
      return null;
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return file;
  }

  /// Starts fetching media art for [games] so it is ready at launch.
  void prefetch(Iterable<Game> games) {
    for (final g in games) {
      unawaited(mediaFor(g).then((_) {}, onError: (Object _) {}));
    }
  }

  /// Copies [image] in as [game]'s custom media art.
  Future<String> storeCustom(Game game, File image) async {
    await Directory(_dir).create(recursive: true);
    final out = _custom(game).path;
    await image.copy(out);
    return out;
  }
}
