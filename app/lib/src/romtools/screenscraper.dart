// SPDX-License-Identifier: GPL-3.0-or-later
// ScreenScraper (screenscraper.fr) API v2 client and the player's account.
// Spec: docs/specs/rom-manager.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/database.dart' show Game;
import '../library/media_art.dart' show screenScraperSystems;
import 'models.dart';

/// A GET's status and body; injectable for tests.
typedef HttpGet = Future<({int status, List<int> body})> Function(Uri url);

/// GETs [url] with a 15 s connect timeout. Any status is returned (no throw
/// on 4xx/5xx); network errors throw.
Future<({int status, List<int> body})> httpGet(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final res = await (await client.getUrl(url)).close();
    final body = <int>[];
    await for (final chunk in res) {
      body.addAll(chunk);
    }
    return (status: res.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

/// A refusal from ScreenScraper: bad login, used-up quota, or another error.
class ScreenScraperError implements Exception {
  const ScreenScraperError(
    this.message, {
    this.quota = false,
    this.badLogin = false,
  });

  final String message;

  /// The daily quota or thread limit was hit; stop the batch.
  final bool quota;

  /// The user name or password (or the build's key) was refused.
  final bool badLogin;

  @override
  String toString() => message;
}

/// The signed-in user's level and quota (`ssuserInfos.php`).
class SsUser {
  const SsUser({
    required this.name,
    required this.level,
    required this.maxThreads,
    required this.requestsToday,
    required this.maxRequestsPerDay,
  });

  final String name;
  final int level, maxThreads, requestsToday, maxRequestsPerDay;
}

/// Talks to ScreenScraper's API v2 with the build's developer key.
class ScreenScraperClient {
  ScreenScraperClient({
    required this.devId,
    required this.devPassword,
    this.get = httpGet,
  });

  /// The build's developer key, or null when the build has none.
  static ScreenScraperClient? fromEnvironment() {
    const id = String.fromEnvironment('DENA_SCREENSCRAPER_DEVID');
    const pw = String.fromEnvironment('DENA_SCREENSCRAPER_DEVPASSWORD');
    if (id.isEmpty || pw.isEmpty) return null;
    return ScreenScraperClient(devId: id, devPassword: pw);
  }

  final String devId, devPassword;
  final HttpGet get;

  static const api = 'https://api.screenscraper.fr/api2';

  /// One request at a time: the free API allows a single thread.
  Future<void> _queue = Future.value();

  Map<String, String> _base(String? user, String? password) => {
    'devid': devId,
    'devpassword': devPassword,
    'softname': 'dena-emu',
    'output': 'json',
    if (user != null && user.isNotEmpty) 'ssid': user,
    if (user != null && user.isNotEmpty) 'sspassword': password ?? '',
  };

  /// Runs [fn] after every earlier request has finished.
  Future<T> _serial<T>(Future<T> Function() fn) {
    final done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await fn());
      } on Object catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  /// Checks [user]'s login with `ssuserInfos.php` and returns their quota.
  /// Throws [ScreenScraperError] with `badLogin` on HTTP 401/403 or an error
  /// text, `quota` on HTTP 429/430/431.
  Future<SsUser> checkUser(String user, String password) => _serial(() async {
    final url = Uri.parse('$api/ssuserInfos.php')
        .replace(queryParameters: _base(user, password));
    final res = await get(url);
    _throwForStatus(res.status);
    final text = utf8.decode(res.body, allowMalformed: true);
    final info = _parseUser(text);
    if (info == null) throw _textError(text, login: true);
    return info;
  });

  /// [game]'s facts and media from `jeuInfos.php`, or null when
  /// ScreenScraper doesn't know it (HTTP 404, "non trouvée") or its system
  /// has no ScreenScraper id. Quota and login errors throw.
  Future<ScrapedGame?> gameInfo(Game game, {String? user, String? password}) {
    final system = screenScraperSystems[game.system];
    if (system == null) return Future.value(null);
    return _serial(() async {
      final url = Uri.parse('$api/jeuInfos.php').replace(
        queryParameters: {
          ..._base(user, password),
          'romtype': 'rom',
          'systemeid': '$system',
          'crc': game.crc32.toUpperCase(),
          'sha1': game.sha1.toUpperCase(),
          'romnom': game.fileName,
          'romtaille': '${game.size}',
        },
      );
      final res = await get(url);
      if (res.status == 404) return null;
      _throwForStatus(res.status);
      final text = utf8.decode(res.body, allowMalformed: true);
      final parsed = parseGame(text, game);
      if (parsed != null) return parsed;
      if (text.toLowerCase().contains('non trouv')) return null;
      throw _textError(text);
    });
  }

  static void _throwForStatus(int status) {
    switch (status) {
      case 200:
        return;
      case 401 || 403:
        throw const ScreenScraperError(
          'ScreenScraper refused the login',
          badLogin: true,
        );
      case 429 || 430 || 431:
        throw const ScreenScraperError(
          'ScreenScraper quota reached; try again tomorrow',
          quota: true,
        );
      default:
        throw ScreenScraperError('ScreenScraper error (HTTP $status)');
    }
  }

  /// An error for a plain-text reply such as `Erreur de login : ...`.
  static ScreenScraperError _textError(String text, {bool login = false}) {
    final t = text.toLowerCase();
    if (t.contains('quota') || t.contains('thread')) {
      return const ScreenScraperError(
        'ScreenScraper quota reached; try again tomorrow',
        quota: true,
      );
    }
    if (login ||
        t.contains('login') ||
        t.contains('identifiant') ||
        t.contains('mot de passe')) {
      return const ScreenScraperError(
        'Wrong ScreenScraper user name or password',
        badLogin: true,
      );
    }
    final line = text.trim().split('\n').first;
    return ScreenScraperError(
      line.isEmpty ? 'ScreenScraper error' : 'ScreenScraper: $line',
    );
  }

  static SsUser? _parseUser(String json) {
    final Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (data case {'response': {'ssuser': final Map<String, Object?> u}}) {
      return SsUser(
        name: '${u['id'] ?? ''}',
        level: _int(u['niveau']),
        maxThreads: _int(u['maxthreads']),
        requestsToday: _int(u['requeststoday']),
        maxRequestsPerDay: _int(u['maxrequestsperday']),
      );
    }
    return null;
  }

  /// Parses a `jeuInfos` JSON reply for [game]; null for invalid JSON or a
  /// reply without a game. Titles and media follow the file name's region,
  /// then ss, us, wor, eu, jp.
  static ScrapedGame? parseGame(String json, Game game) {
    final Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (data case {'response': {'jeu': final Map<String, Object?> jeu}}) {
      final regions = [
        ..._fileRegions(game.fileName),
        'ss',
        'us',
        'wor',
        'eu',
        'jp',
      ];
      final media = <ScrapeKind, Uri>{};
      final list = jeu['medias'];
      if (list is List) {
        for (final kind in ScrapeKind.values) {
          final url = _pickMedia(list, _mediaTypes[kind]!, regions);
          if (url != null) media[kind] = url;
        }
      }
      return ScrapedGame(
        source: 'screenscraper',
        title: _byKey(jeu['noms'], 'region', regions),
        description: _byKey(jeu['synopsis'], 'langue', const ['en']),
        developer: _text(jeu['developpeur']),
        publisher: _text(jeu['editeur']),
        genre: _genre(jeu['genres']),
        year: _year(jeu['dates']),
        players: _text(jeu['joueurs']),
        media: media,
      );
    }
    return null;
  }

  static const _mediaTypes = {
    ScrapeKind.cover: ['box-2D'],
    ScrapeKind.box3d: ['box-3D'],
    ScrapeKind.back: ['box-2D-back'],
    ScrapeKind.screenshot: ['ss'],
    ScrapeKind.manual: ['manuel'],
    ScrapeKind.video: ['video-normalized', 'video'],
  };

  static Uri? _pickMedia(
    List<Object?> media,
    List<String> types,
    List<String> regions,
  ) {
    for (final type in types) {
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
    return null;
  }

  /// The `text` of the entry in [list] whose [key] comes first in [order],
  /// else the first entry's.
  static String? _byKey(Object? list, String key, List<String> order) {
    if (list is! List) return null;
    final entries = [
      for (final e in list)
        if (e case {'text': final String t} when t.trim().isNotEmpty) e,
    ];
    if (entries.isEmpty) return null;
    for (final want in order) {
      for (final e in entries) {
        if (e[key] == want) return (e['text'] as String).trim();
      }
    }
    return (entries.first['text'] as String).trim();
  }

  static String? _text(Object? v) {
    if (v case {'text': final String t} when t.trim().isNotEmpty) {
      return t.trim();
    }
    return null;
  }

  static String? _genre(Object? genres) {
    if (genres case [{'noms': final Object? noms}, ...]) {
      return _byKey(noms, 'langue', const ['en']);
    }
    return null;
  }

  static int? _year(Object? dates) {
    if (dates is! List) return null;
    int? best;
    for (final d in dates) {
      if (d case {'text': final String t}) {
        final m = RegExp(r'\b(1[89]\d\d|20\d\d)\b').firstMatch(t);
        final y = m == null ? null : int.parse(m[1]!);
        if (y != null && (best == null || y < best)) best = y;
      }
    }
    return best;
  }

  static int _int(Object? v) => switch (v) {
    final int i => i,
    final String s => int.tryParse(s) ?? 0,
    _ => 0,
  };
}

/// ScreenScraper region codes named in a No-Intro file name's tags
/// (`(USA, Europe)` → us, eu), as media_art.dart picks them.
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

/// The player's ScreenScraper account, kept in
/// `<dataDir>/romtools/screenscraper.json` (`{"user", "password"}`). The
/// password is stored because every request needs it: ScreenScraper has no
/// tokens. It is only ever sent to screenscraper.fr.
class ScreenScraperAccount extends ChangeNotifier {
  ScreenScraperAccount(this.dataDir, {this.client});

  final String dataDir;

  /// Null when this build has no developer key.
  final ScreenScraperClient? client;

  /// False when this build has no ScreenScraper developer key.
  bool get available => client != null;

  String? _user, _password;
  SsUser? _info;

  String? get user => _user;
  String? get password => _password;

  /// The quota last read from ScreenScraper, if any.
  SsUser? get info => _info;

  /// Whether a login is stored and this build can use it.
  bool get signedIn => available && _user != null;

  File get _file => File(p.join(dataDir, 'romtools', 'screenscraper.json'));

  /// Reads the stored login, if any.
  Future<void> load() async {
    try {
      final data = jsonDecode(await _file.readAsString());
      if (data case {'user': final String u, 'password': final String pw}) {
        _user = u;
        _password = pw;
      }
    } on Object {
      _user = _password = null;
    }
    notifyListeners();
  }

  /// Checks and stores the login. Returns null on success, else the message
  /// to show.
  Future<String?> signIn(String user, String password) async {
    final c = client;
    if (c == null) return 'This build has no ScreenScraper key';
    final SsUser info;
    try {
      info = await c.checkUser(user, password);
    } on ScreenScraperError catch (e) {
      return e.message;
    } on Object {
      return 'Could not reach ScreenScraper';
    }
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode({'user': user, 'password': password}));
    await tmp.rename(_file.path);
    _user = user;
    _password = password;
    _info = info;
    notifyListeners();
    return null;
  }

  /// Forgets the stored login.
  Future<void> signOut() async {
    if (await _file.exists()) await _file.delete();
    _user = _password = null;
    _info = null;
    notifyListeners();
  }

  /// Re-reads the quota; errors are ignored.
  Future<void> refresh() async {
    final c = client, u = _user;
    if (c == null || u == null) return;
    try {
      _info = await c.checkUser(u, _password ?? '');
      notifyListeners();
    } on Object {
      // Keep the last quota.
    }
  }
}
