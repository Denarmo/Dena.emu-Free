import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/media_art.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Game game({
  String sha1 = 'abc',
  String system = 'gba',
  String fileName = 'a.gba',
  String path = '/x/a.gba',
}) => Game(
  id: 1,
  system: system,
  title: 'Agent Game',
  searchTitle: 'agent game',
  fileName: fileName,
  path: path,
  sha1: sha1,
  size: 1,
  crc32: 'caf2e99f',
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
);

class FakeSource implements MediaArtSource {
  Uri? answer = Uri.parse('https://media.test/label.png');
  Object? error;
  int calls = 0;

  @override
  Future<Uri?> find(Game game, {String? name}) async {
    calls++;
    if (error case final e?) throw e;
    return answer;
  }
}

String reply(List<Map<String, String>> media) => jsonEncode({
  'response': {
    'jeu': {'medias': media},
  },
});

void main() {
  test('each system loads the media it shipped on', () {
    expect(mediaKindFor('gba'), MediaKind.cartridge);
    expect(mediaKindFor('nes'), MediaKind.cartridge);
    expect(mediaKindFor('nds'), MediaKind.cartridge);
    expect(mediaKindFor('genesis'), MediaKind.cartridge);
    expect(mediaKindFor('psx'), MediaKind.disc);
    expect(mediaKindFor('dreamcast'), MediaKind.disc);
    expect(mediaKindFor('psp'), MediaKind.umd);
    expect(mediaKindFor('pico8'), MediaKind.pico8Cart);
  });

  group('ScreenScraper replies', () {
    test('cartridges take the label texture in the file\'s region', () {
      final json = reply([
        {'type': 'box-2D', 'region': 'us', 'url': 'https://x/box'},
        {'type': 'support-2D', 'region': 'us', 'url': 'https://x/scan'},
        {'type': 'support-texture', 'region': 'jp', 'url': 'https://x/jp'},
        {'type': 'support-texture', 'region': 'eu', 'url': 'https://x/eu'},
      ]);
      expect(
        ScreenScraperSource.pickMedia(
          json,
          game(fileName: 'Game (Europe).gba'),
        ).toString(),
        'https://x/eu',
      );
      // No region named: USA, World, Europe, Japan.
      expect(
        ScreenScraperSource.pickMedia(json, game()).toString(),
        'https://x/eu',
      );
    });

    test('discs take the face scan', () {
      final json = reply([
        {'type': 'support-texture', 'region': 'us', 'url': 'https://x/tex'},
        {'type': 'support-2D', 'region': 'jp', 'url': 'https://x/disc'},
      ]);
      expect(
        ScreenScraperSource.pickMedia(json, game(system: 'psx')).toString(),
        'https://x/disc',
      );
    });

    test('no media or a plain-text error is a miss', () {
      expect(ScreenScraperSource.pickMedia(reply([]), game()), isNull);
      expect(
        ScreenScraperSource.pickMedia('Erreur : Rom non trouvée !', game()),
        isNull,
      );
    });

    test('lookups name the system and the ROM hashes', () {
      final s = ScreenScraperSource(devId: 'id', devPassword: 'pw');
      final q = s.lookupUrl(game(system: 'psp')).queryParameters;
      expect(q['systemeid'], '61');
      expect(q['crc'], 'CAF2E99F');
      expect(q['output'], 'json');
    });

    test('lookups run one at a time', () async {
      var running = 0, most = 0;
      final s = ScreenScraperSource(
        devId: 'id',
        devPassword: 'pw',
        fetch: (_) async {
          running++;
          most = running > most ? running : most;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          running--;
          return utf8.encode(reply([]));
        },
      );
      await Future.wait([s.find(game()), s.find(game(sha1: 'b'))]);
      expect(most, 1);
    });
  });

  group('MediaArtCache', () {
    late Directory dir;
    late FakeSource source;
    late int downloads;

    MediaArtCache cache({DateTime Function()? clock}) => MediaArtCache(
      dir.path,
      source: source,
      clock: clock ?? DateTime.now,
      fetch: (url) async {
        downloads++;
        return [1, 2, 3];
      },
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('media_art');
      source = FakeSource();
      downloads = 0;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('downloads once and caches next to the covers', () async {
      final c = cache();
      final f = await c.mediaFor(game());
      expect(f!.path, p.join(dir.path, 'art', 'abc.media.png'));
      expect(await f.readAsBytes(), [1, 2, 3]);
      expect(c.cachedFor(game())?.path, f.path);
      await c.mediaFor(game());
      expect(downloads, 1);
    });

    test('a miss is remembered; a failure is retried', () async {
      source.answer = null;
      final c = cache();
      expect(await c.mediaFor(game()), isNull);
      expect(
        File(p.join(dir.path, 'art', 'abc.media.none')).existsSync(),
        true,
      );
      await c.mediaFor(game());
      expect(source.calls, 1);

      source
        ..answer = Uri.parse('https://x')
        ..error = const SocketException('offline');
      final other = game(sha1: 'def');
      expect(await c.mediaFor(other), isNull);
      expect(Directory(p.join(dir.path, 'art')).listSync().length, 1);
      // A fresh start (new cache) tries again.
      source.error = null;
      expect(await cache().mediaFor(other), isNotNull);
    });

    test('custom media art wins', () async {
      final c = cache();
      final img = File(p.join(dir.path, 'mine.png'))..writeAsBytesSync([9]);
      await c.storeCustom(game(), img);
      expect(await (await c.mediaFor(game()))!.readAsBytes(), [9]);
      expect(source.calls, 0);
    });

    test('a PICO-8 cart is its own label; no source means none', () async {
      final png = File(p.join(dir.path, 'cart.p8.png'))..writeAsBytesSync([7]);
      final c = MediaArtCache(dir.path);
      expect(
        (await c.mediaFor(game(system: 'pico8', path: png.path)))?.path,
        png.path,
      );
      expect(await c.mediaFor(game()), isNull);
    });
  });
}
