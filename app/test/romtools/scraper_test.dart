// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/rom-manager.md (acceptance test 5)
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart' show Game;
import 'package:dena_emu/src/romtools/models.dart';
import 'package:dena_emu/src/romtools/openvgdb.dart';
import 'package:dena_emu/src/romtools/scraper.dart';
import 'package:dena_emu/src/romtools/screenscraper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Game game(String sha1) => Game(
  id: 1,
  system: 'snes',
  title: 'Hero',
  searchTitle: 'hero',
  fileName: 'Hero (USA).sfc',
  path: '/x/hero.sfc',
  sha1: sha1,
  size: 1,
  crc32: 'caf2e99f',
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
);

/// OpenVGDB with canned answers.
class FakeVgdb extends OpenVgdb {
  FakeVgdb(super.dataDir, this.answer);
  final ScrapedGame? answer;

  @override
  Future<ScrapedGame?> lookup(Game game) async => answer;
}

const ssUser = {
  'response': {
    'ssuser': {'id': 'player', 'niveau': '1'},
  },
};

Map<String, Object?> ssGame(List<(String, String)> media) => {
  'response': {
    'jeu': {
      'noms': [
        {'region': 'us', 'text': 'Hero SS'},
      ],
      'developpeur': {'text': 'SS Dev'},
      'medias': [
        for (final (type, url) in media)
          {'type': type, 'region': 'us', 'url': url},
      ],
    },
  },
};

final offline = ScrapedGame(
  source: 'openvgdb',
  title: 'Hero OV',
  developer: 'OV Dev',
  publisher: 'OV Pub',
  year: 1991,
  media: {
    ScrapeKind.cover: Uri.parse('https://ov/front.jpg'),
    ScrapeKind.back: Uri.parse('https://ov/back.jpg'),
  },
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('scraper'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ScreenScraperAccount> account(
    Future<({int status, List<int> body})> Function(Uri) jeu,
  ) async {
    final a = ScreenScraperAccount(
      dir.path,
      client: ScreenScraperClient(
        devId: 'd',
        devPassword: 'p',
        get: (url) async => url.path.endsWith('ssuserInfos.php')
            ? (status: 200, body: utf8.encode(jsonEncode(ssUser)))
            : jeu(url),
      ),
    );
    expect(await a.signIn('player', 'pw'), isNull);
    return a;
  }

  final fetched = <Uri>[];
  Future<List<int>?> fetch(Uri url) async {
    fetched.add(url);
    if (url.host == 'broken') throw const SocketException('down');
    return utf8.encode('img:$url');
  }

  setUp(fetched.clear);

  test('ScreenScraper wins, OpenVGDB fills gaps; files written', () async {
    final ss = await account(
      (_) async => (
        status: 200,
        body: utf8.encode(
          jsonEncode(
            ssGame([
              ('box-2D', 'https://ss/cover'),
              ('ss', 'https://ss/snap'),
              ('manuel', 'https://ss/manual'),
              ('video', 'https://ss/video'),
            ]),
          ),
        ),
      ),
    );
    final scraper = Scraper(
      dir.path,
      openVgdb: FakeVgdb(dir.path, offline),
      screenScraper: ss,
      fetch: fetch,
      kinds: () => ScrapeKind.small,
    );
    final g = game('aaa');
    final out = await scraper.scrape(g);
    expect(out, isA<ScrapeDone>());
    final files = (out as ScrapeDone).files;
    expect(files.files.keys.toSet(), {
      ScrapeKind.cover,
      ScrapeKind.back,
      ScrapeKind.screenshot,
    });
    expect(
      files.files[ScrapeKind.cover]!.readAsStringSync(),
      'img:https://ss/cover',
    );
    expect(
      files.files[ScrapeKind.back]!.readAsStringSync(),
      'img:https://ov/back.jpg',
    );
    expect(
      p.basename(files.files[ScrapeKind.screenshot]!.path),
      'screenshot.png',
    );
    // The phone set: no manual or video.
    expect(fetched.map((u) => u.path), isNot(contains('/manual')));
    expect(fetched.map((u) => u.path), isNot(contains('/video')));
    expect(files.info!.source, 'screenscraper');
    expect(files.info!.title, 'Hero SS');
    expect(files.info!.developer, 'SS Dev');
    expect(files.info!.publisher, 'OV Pub');
    expect(files.info!.year, 1991);
    expect(scraper.filesFor(g).info!.title, 'Hero SS');
    expect(scraper.hasAny(g), isTrue);

    // Already on disk: not fetched again.
    fetched.clear();
    await scraper.scrape(g);
    expect(fetched, isEmpty);

    await scraper.forget(g);
    expect(scraper.hasAny(g), isFalse);
    expect(Directory(p.join(dir.path, 'scrape', 'aaa')).existsSync(), isFalse);
  });

  test('desktop kinds fetch manuals and videos', () async {
    final ss = await account(
      (_) async => (
        status: 200,
        body: utf8.encode(
          jsonEncode(
            ssGame([
              ('manuel', 'https://ss/manual'),
              ('video', 'https://ss/video'),
            ]),
          ),
        ),
      ),
    );
    final scraper = Scraper(
      dir.path,
      screenScraper: ss,
      fetch: fetch,
      kinds: () => ScrapeKind.values.toSet(),
    );
    final out = await scraper.scrape(game('ddd')) as ScrapeDone;
    expect(p.basename(out.files.files[ScrapeKind.manual]!.path), 'manual.pdf');
    expect(p.basename(out.files.files[ScrapeKind.video]!.path), 'video.mp4');
  });

  test('cover goes to art/ only when absent; the miss marker goes', () async {
    final scraper = Scraper(
      dir.path,
      openVgdb: FakeVgdb(dir.path, offline),
      fetch: fetch,
      kinds: () => ScrapeKind.small,
    );
    final art = Directory(p.join(dir.path, 'art'))..createSync();
    File(p.join(art.path, 'bbb.none')).writeAsStringSync('m3');
    await scraper.scrape(game('bbb'));
    expect(
      File(p.join(art.path, 'bbb.png')).readAsStringSync(),
      'img:https://ov/front.jpg',
    );
    expect(File(p.join(art.path, 'bbb.none')).existsSync(), isFalse);

    File(p.join(art.path, 'ccc.png')).writeAsStringSync('existing');
    await scraper.scrape(game('ccc'));
    expect(File(p.join(art.path, 'ccc.png')).readAsStringSync(), 'existing');
  });

  test(
    'nothing known is a miss; a failed download does not stop others',
    () async {
      final miss = Scraper(
        dir.path,
        openVgdb: FakeVgdb(dir.path, null),
        fetch: fetch,
        kinds: () => ScrapeKind.small,
      );
      expect(await miss.scrape(game('eee')), isA<ScrapeMiss>());

      final partial = Scraper(
        dir.path,
        openVgdb: FakeVgdb(
          dir.path,
          ScrapedGame(
            source: 'openvgdb',
            media: {
              ScrapeKind.cover: Uri.parse('https://broken/front.jpg'),
              ScrapeKind.back: Uri.parse('https://ov/back.jpg'),
            },
          ),
        ),
        fetch: fetch,
        kinds: () => ScrapeKind.small,
      );
      final out = await partial.scrape(game('fff')) as ScrapeDone;
      expect(out.files.files.keys, [ScrapeKind.back]);
    },
  );

  test('quota stops scrapeAll with a problem', () async {
    var calls = 0;
    final ss = await account((_) async {
      calls++;
      return (status: 430, body: <int>[]);
    });
    final scraper = Scraper(
      dir.path,
      openVgdb: FakeVgdb(dir.path, offline),
      screenScraper: ss,
      fetch: fetch,
      kinds: () => ScrapeKind.small,
    );
    final out = await scraper.scrape(game('ggg'));
    expect(out, isA<ScrapeFailed>().having((f) => f.quota, 'quota', true));
    calls = 0;
    await scraper.scrapeAll([game('h1'), game('h2'), game('h3')]);
    expect(calls, 1);
    expect(scraper.running, isFalse);
    expect(scraper.done, 1);
    expect(scraper.total, 3);
    expect(scraper.problem, contains('quota'));
  });

  test('scrapeAll skips scraped games unless forced; cancel stops', () async {
    final scraper = Scraper(
      dir.path,
      openVgdb: FakeVgdb(dir.path, offline),
      fetch: fetch,
      kinds: () => ScrapeKind.small,
    );
    await scraper.scrape(game('i1'));
    await scraper.scrapeAll([game('i1'), game('i2')]);
    expect(scraper.total, 1);
    expect(scraper.done, 1);
    expect(scraper.problem, isNull);
    await scraper.scrapeAll([game('i1'), game('i2')], force: true);
    expect(scraper.total, 2);

    var seen = 0;
    void listener() {
      if (scraper.done == 1 && seen++ == 0) scraper.cancel();
    }

    scraper.addListener(listener);
    await scraper.scrapeAll([game('j1'), game('j2'), game('j3')], force: true);
    expect(scraper.done, 1);
  });
}
