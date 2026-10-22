// SPDX-License-Identifier: GPL-3.0-or-later
// Scraper: merges ScreenScraper and OpenVGDB and downloads the media.
// Spec: docs/specs/rom-manager.md
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/box_art.dart' show Fetch, httpFetch;
import '../library/database.dart' show Game;
import 'models.dart';
import 'openvgdb.dart';
import 'screenscraper.dart';

/// A game's scraped media on disk and its facts (`info.json`).
class ScrapedFiles {
  const ScrapedFiles(this.files, this.info);

  final Map<ScrapeKind, File> files;
  final ScrapedGame? info;

  bool get isEmpty => files.isEmpty && info == null;
}

/// The result of [Scraper.scrape].
sealed class ScrapeOutcome {
  const ScrapeOutcome();
}

/// Something was found; [files] is what is on disk now.
class ScrapeDone extends ScrapeOutcome {
  const ScrapeDone(this.files);
  final ScrapedFiles files;
}

/// No source knows the game.
class ScrapeMiss extends ScrapeOutcome {
  const ScrapeMiss();
}

/// The lookup or every download failed; [quota] when ScreenScraper's
/// daily quota is used up.
class ScrapeFailed extends ScrapeOutcome {
  const ScrapeFailed(this.message, {this.quota = false});
  final String message;
  final bool quota;
}

/// Scrapes games into `<dataDir>/scrape/<sha1>/`: ScreenScraper first when
/// signed in, OpenVGDB filling the gaps. On demand only, never automatic.
class Scraper extends ChangeNotifier {
  Scraper(
    this.dataDir, {
    this.openVgdb,
    this.screenScraper,
    this.fetch = httpFetch,
    required this.kinds,
  });

  final String dataDir;
  final OpenVgdb? openVgdb;
  final ScreenScraperAccount? screenScraper;
  final Fetch fetch;

  /// The media kinds this device fetches ([ScrapeKind.small] on phones and
  /// handhelds, every kind on desktop).
  final Set<ScrapeKind> Function() kinds;

  bool _running = false, _cancel = false;
  int _done = 0, _total = 0;
  String? _problem;

  /// Whether [scrapeAll] is running.
  bool get running => _running;
  int get done => _done;
  int get total => _total;

  /// The last batch's failure message (a quota stop), if any.
  String? get problem => _problem;

  Directory _dir(Game game) => Directory(p.join(dataDir, 'scrape', game.sha1));

  File _file(Game game, ScrapeKind kind) =>
      File(p.join(_dir(game).path, '${kind.name}${kind.extension}'));

  File _info(Game game) => File(p.join(_dir(game).path, 'info.json'));

  /// Looks [game] up and downloads each wanted kind not yet on disk. The
  /// cover also becomes the library cover (`art/<sha1>.png`) when the
  /// box-art cache has none. One failed download doesn't stop the others.
  Future<ScrapeOutcome> scrape(Game game) async {
    ScrapedGame? info;
    final account = screenScraper;
    final client = account?.client;
    if (account != null && client != null && account.signedIn) {
      try {
        info = await client.gameInfo(
          game,
          user: account.user,
          password: account.password,
        );
      } on ScreenScraperError catch (e) {
        return ScrapeFailed(e.message, quota: e.quota);
      } on Object {
        return const ScrapeFailed('Could not reach ScreenScraper');
      }
    }
    ScrapedGame? offline;
    try {
      offline = await openVgdb?.lookup(game);
    } on Object {
      offline = null; // A damaged database is a miss, not a failure.
    }
    if (offline != null) info = info?.merge(offline) ?? offline;
    if (info == null) return const ScrapeMiss();

    final dir = _dir(game);
    await dir.create(recursive: true);
    var failed = 0;
    for (final kind in kinds()) {
      final url = info.media[kind];
      final out = _file(game, kind);
      if (url == null || await out.exists()) continue;
      try {
        final bytes = await fetch(url);
        if (bytes == null || bytes.isEmpty) continue;
        final tmp = File('${out.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(out.path);
      } on Object {
        failed++;
      }
    }
    await _write(_info(game), utf8.encode(jsonEncode(info.toJson())));
    await _useCover(game);
    final files = filesFor(game);
    if (failed > 0 && files.files.isEmpty) {
      return const ScrapeFailed('Could not download the media');
    }
    return ScrapeDone(files);
  }

  /// Copies the scraped cover to `art/<sha1>.png` when there is none, and
  /// drops the box-art miss marker so the library shows it.
  Future<void> _useCover(Game game) async {
    final cover = _file(game, ScrapeKind.cover);
    if (!await cover.exists()) return;
    final art = File(p.join(dataDir, 'art', '${game.sha1}.png'));
    if (await art.exists()) return;
    await art.parent.create(recursive: true);
    await _write(art, await cover.readAsBytes());
    final none = File(p.join(dataDir, 'art', '${game.sha1}.none'));
    if (await none.exists()) await none.delete();
  }

  static Future<void> _write(File file, List<int> bytes) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  /// [game]'s scraped files and facts on disk.
  ScrapedFiles filesFor(Game game) {
    final files = <ScrapeKind, File>{
      for (final kind in ScrapeKind.values)
        if (_file(game, kind).existsSync()) kind: _file(game, kind),
    };
    ScrapedGame? info;
    try {
      final data = jsonDecode(_info(game).readAsStringSync());
      if (data is Map<String, Object?>) info = ScrapedGame.fromJson(data);
    } on Object {
      info = null;
    }
    return ScrapedFiles(files, info);
  }

  /// Whether anything has been scraped for [game].
  bool hasAny(Game game) => !filesFor(game).isEmpty;

  /// Scrapes [games] one at a time, skipping those already scraped unless
  /// [force]. Stops on a quota failure with [problem] set, or after the
  /// current game when [cancel] is called.
  Future<void> scrapeAll(List<Game> games, {bool force = false}) async {
    if (_running) return;
    final todo = [
      for (final g in games)
        if (force || !hasAny(g)) g,
    ];
    _running = true;
    _cancel = false;
    _done = 0;
    _total = todo.length;
    _problem = null;
    notifyListeners();
    try {
      for (final game in todo) {
        if (_cancel) break;
        final outcome = await scrape(game);
        _done++;
        if (outcome case ScrapeFailed(:final message, :final quota)) {
          _problem = message;
          if (quota) break;
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// Stops [scrapeAll] after the current game.
  void cancel() => _cancel = true;

  /// Deletes `<dataDir>/scrape/<sha1>/`.
  Future<void> forget(Game game) async {
    final dir = _dir(game);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
