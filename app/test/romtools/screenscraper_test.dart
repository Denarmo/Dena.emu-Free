// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/rom-manager.md (acceptance test 5)
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/romtools/models.dart';
import 'package:dena_emu/src/romtools/screenscraper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Game game({String system = 'snes', String fileName = 'Hero (Europe).sfc'}) =>
    Game(
      id: 1,
      system: system,
      title: 'Hero',
      searchTitle: 'hero',
      fileName: fileName,
      path: '/x/$fileName',
      sha1: 'abc123',
      size: 524288,
      crc32: 'caf2e99f',
      addedAt: DateTime(2026),
      playSeconds: 0,
      favorite: false,
    );

({int status, List<int> body}) reply(Object body, [int status = 200]) => (
  status: status,
  body: utf8.encode(body is String ? body : jsonEncode(body)),
);

const userJson = {
  'response': {
    'ssuser': {
      'id': 'player',
      'niveau': '1',
      'maxthreads': '1',
      'requeststoday': '12',
      'maxrequestsperday': '20000',
    },
  },
};

final gameJson = {
  'response': {
    'jeu': {
      'noms': [
        {'region': 'jp', 'text': 'Yuusha'},
        {'region': 'us', 'text': 'Hero USA'},
        {'region': 'eu', 'text': 'Hero Europe'},
      ],
      'synopsis': [
        {'langue': 'fr', 'text': 'Un héros.'},
        {'langue': 'en', 'text': 'A hero.'},
      ],
      'developpeur': {'id': '1', 'text': 'Dev Co'},
      'editeur': {'id': '2', 'text': 'Pub Co'},
      'genres': [
        {
          'id': '3',
          'noms': [
            {'langue': 'de', 'text': 'Abenteuer'},
            {'langue': 'en', 'text': 'Adventure'},
          ],
        },
      ],
      'dates': [
        {'region': 'us', 'text': '1993-05-01'},
        {'region': 'jp', 'text': '1992-11-20'},
      ],
      'joueurs': {'text': '1-2'},
      'medias': [
        {'type': 'box-2D', 'region': 'us', 'url': 'https://ss/cover-us'},
        {'type': 'box-2D', 'region': 'eu', 'url': 'https://ss/cover-eu'},
        {'type': 'box-3D', 'region': 'jp', 'url': 'https://ss/box3d-jp'},
        {'type': 'box-2D-back', 'region': 'us', 'url': 'https://ss/back-us'},
        {'type': 'ss', 'region': 'wor', 'url': 'https://ss/snap'},
        {'type': 'manuel', 'region': 'us', 'url': 'https://ss/manual'},
        {'type': 'video', 'url': 'https://ss/video'},
        {'type': 'video-normalized', 'url': 'https://ss/video-n'},
      ],
    },
  },
};

void main() {
  test('fromEnvironment is null without a developer key', () {
    expect(ScreenScraperClient.fromEnvironment(), isNull);
  });

  test('checkUser parses the quota and sends the login', () async {
    Uri? asked;
    final c = ScreenScraperClient(
      devId: 'dev',
      devPassword: 'devpw',
      get: (url) async {
        asked = url;
        return reply(userJson);
      },
    );
    final u = await c.checkUser('player', 'secret');
    expect(u.name, 'player');
    expect(u.level, 1);
    expect(u.maxThreads, 1);
    expect(u.requestsToday, 12);
    expect(u.maxRequestsPerDay, 20000);
    expect(asked!.path, '/api2/ssuserInfos.php');
    expect(asked!.queryParameters, containsPair('ssid', 'player'));
    expect(asked!.queryParameters, containsPair('sspassword', 'secret'));
    expect(asked!.queryParameters, containsPair('devid', 'dev'));
    expect(asked!.queryParameters, containsPair('softname', 'dena-emu'));
  });

  test('bad login: HTTP 403 and an error text', () async {
    for (final r in [
      reply('', 403),
      reply('Erreur : Login utilisateur ou mot de passe incorrect'),
    ]) {
      final c = ScreenScraperClient(
        devId: 'd',
        devPassword: 'p',
        get: (_) async => r,
      );
      await expectLater(
        c.checkUser('a', 'b'),
        throwsA(
          isA<ScreenScraperError>().having((e) => e.badLogin, 'badLogin', true),
        ),
      );
    }
  });

  test('quota errors throw for every code', () async {
    for (final code in [429, 430, 431]) {
      final c = ScreenScraperClient(
        devId: 'd',
        devPassword: 'p',
        get: (_) async => reply('', code),
      );
      await expectLater(
        c.gameInfo(game()),
        throwsA(
          isA<ScreenScraperError>().having((e) => e.quota, 'quota', true),
        ),
      );
    }
  });

  test('gameInfo sends the login, key and hashes', () async {
    Uri? asked;
    final c = ScreenScraperClient(
      devId: 'dev',
      devPassword: 'devpw',
      get: (url) async {
        asked = url;
        return reply(gameJson);
      },
    );
    final g = await c.gameInfo(game(), user: 'player', password: 'secret');
    expect(g!.title, 'Hero Europe');
    final q = asked!.queryParameters;
    expect(asked!.path, '/api2/jeuInfos.php');
    expect(q['ssid'], 'player');
    expect(q['sspassword'], 'secret');
    expect(q['devid'], 'dev');
    expect(q['devpassword'], 'devpw');
    expect(q['systemeid'], '4');
    expect(q['crc'], 'CAF2E99F');
    expect(q['sha1'], 'ABC123');
    expect(q['romnom'], 'Hero (Europe).sfc');
    expect(q['romtaille'], '524288');
  });

  test('gameInfo: misses and unknown systems', () async {
    var calls = 0;
    final c = ScreenScraperClient(
      devId: 'd',
      devPassword: 'p',
      get: (url) async {
        calls++;
        return url.queryParameters['crc'] == 'CAF2E99F'
            ? reply('Erreur : Rom/Iso/Dossier non trouvée !')
            : reply('', 404);
      },
    );
    expect(await c.gameInfo(game()), isNull);
    expect(await c.gameInfo(game().copyWith(crc32: '00000000')), isNull);
    expect(calls, 2);
    expect(await c.gameInfo(game(system: 'pico8')), isNull);
    expect(calls, 2);
  });

  test('requests run one at a time', () async {
    var active = 0, peak = 0;
    final c = ScreenScraperClient(
      devId: 'd',
      devPassword: 'p',
      get: (_) async {
        peak = ++active > peak ? active : peak;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return reply(gameJson);
      },
    );
    await Future.wait([for (var i = 0; i < 3; i++) c.gameInfo(game())]);
    expect(peak, 1);
  });

  test('parseGame picks facts and media per kind and region', () {
    final g = ScreenScraperClient.parseGame(jsonEncode(gameJson), game())!;
    expect(g.source, 'screenscraper');
    expect(g.title, 'Hero Europe');
    expect(g.description, 'A hero.');
    expect(g.developer, 'Dev Co');
    expect(g.publisher, 'Pub Co');
    expect(g.genre, 'Adventure');
    expect(g.year, 1992);
    expect(g.players, '1-2');
    expect(g.media, {
      ScrapeKind.cover: Uri.parse('https://ss/cover-eu'),
      ScrapeKind.box3d: Uri.parse('https://ss/box3d-jp'),
      ScrapeKind.back: Uri.parse('https://ss/back-us'),
      ScrapeKind.screenshot: Uri.parse('https://ss/snap'),
      ScrapeKind.manual: Uri.parse('https://ss/manual'),
      ScrapeKind.video: Uri.parse('https://ss/video-n'),
    });
    // No region in the name: us before eu.
    final us = ScreenScraperClient.parseGame(
      jsonEncode(gameJson),
      game(fileName: 'hero.sfc'),
    )!;
    expect(us.title, 'Hero USA');
    expect(us.media[ScrapeKind.cover], Uri.parse('https://ss/cover-us'));
  });

  test('parseGame: invalid JSON is null', () {
    expect(ScreenScraperClient.parseGame('Erreur', game()), isNull);
  });

  group('account', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ss_account'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('unavailable without a key', () async {
      final a = ScreenScraperAccount(dir.path);
      expect(a.available, isFalse);
      expect(await a.signIn('a', 'b'), 'This build has no ScreenScraper key');
      expect(a.signedIn, isFalse);
    });

    test('sign in, persist, sign out', () async {
      final client = ScreenScraperClient(
        devId: 'd',
        devPassword: 'p',
        get: (url) async => url.queryParameters['sspassword'] == 'secret'
            ? reply(userJson)
            : reply('', 401),
      );
      final a = ScreenScraperAccount(dir.path, client: client);
      expect(await a.signIn('player', 'wrong'), isNotNull);
      expect(a.signedIn, isFalse);
      expect(await a.signIn('player', 'secret'), isNull);
      expect(a.signedIn, isTrue);
      expect(a.info!.requestsToday, 12);

      final again = ScreenScraperAccount(dir.path, client: client);
      await again.load();
      expect(again.user, 'player');
      expect(again.password, 'secret');
      expect(again.signedIn, isTrue);
      await again.refresh();
      expect(again.info!.maxRequestsPerDay, 20000);

      await again.signOut();
      expect(again.signedIn, isFalse);
      final third = ScreenScraperAccount(dir.path, client: client);
      await third.load();
      expect(third.user, isNull);
      expect(
        File(p.join(dir.path, 'romtools', 'screenscraper.json')).existsSync(),
        isFalse,
      );
    });
  });
}
