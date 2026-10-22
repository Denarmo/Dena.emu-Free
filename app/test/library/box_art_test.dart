import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/box_art.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/games_tab.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/library/romhacks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

/// A 4×3 red PNG.
final coverPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGM4YWMDRww4OQArRg8Bc3oMDAAAAABJRU5ErkJggg==',
);

Game game({
  String sha1 = 'abc',
  String crc = 'caf2e99f',
  String? custom,
  String system = 'gba',
  String fileName = 'a.gba',
  String path = '/x/a.gba',
  String title = 'Agent Game',
}) => Game(
  id: 1,
  system: system,
  title: title,
  searchTitle: title.toLowerCase(),
  fileName: fileName,
  path: path,
  sha1: sha1,
  size: 1,
  crc32: crc,
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
  customArtPath: custom,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('thumbnail URLs escape the characters the server replaces', () {
    expect(
      boxArtUrl('gba', 'Mario & Luigi - Superstar Saga (USA)').toString(),
      'https://thumbnails.libretro.com/Nintendo%20-%20Game%20Boy%20Advance/'
      'Named_Boxarts/Mario%20_%20Luigi%20-%20Superstar%20Saga%20(USA).png',
    );
    expect(boxArtUrl('snes', 'A/B: C?').pathSegments.last, 'A_B_ C_.png');
  });

  test('the bundled index finds games by CRC for every system', () async {
    final index = await BoxArtIndex.load();
    expect(
      index.nameFor('gba', 'CAF2E99F'),
      '007 - Everything or Nothing (Japan)',
    );
    expect(index.nameFor('gba', '00000000'), isNull);
    for (final s in boxArtSystems.keys) {
      expect(index.nameFor(s, 'ffffffff'), isNull, reason: s);
    }
  });

  test('titleKey folds articles, tags, separators and ampersands', () {
    expect(
      titleKey('Legend of Zelda, The - A Link to the Past (USA).sfc'),
      titleKey('the_legend_of_zelda_a_link_to_the_past.smc'),
    );
    expect(
      titleKey('Mario & Luigi - Superstar Saga (USA)'),
      titleKey('Mario and Luigi - Superstar Saga.gba'),
    );
  });

  test('hackKey drops romhack and version noise', () {
    expect(
      hackKey('Super Mario World (Hack) Kaizo v1.2.sfc'),
      hackKey('Super Mario World'),
    );
    expect(
      hackKey('Super Mario World (Hack) Kaizo v1.2.sfc'),
      'super mario world',
    );
  });

  test('nameForFile prefers a matching region, then USA, and final builds', () {
    const tsv =
        'snes\t00000001\tHero Quest (Japan)\n'
        'snes\t00000002\tHero Quest (USA)\n'
        'snes\t00000003\tHero Quest (Europe)\n'
        'snes\t00000004\tHero Quest (USA) (Beta)\n';
    final index = BoxArtIndex.parse(tsv);
    expect(
      index.nameForFile('snes', 'Hero Quest (Europe).sfc'),
      'Hero Quest (Europe)',
    );
    expect(index.nameForFile('snes', 'hero_quest.sfc'), 'Hero Quest (USA)');
    expect(index.nameForFile('snes', 'Nonexistent (USA).sfc'), isNull);
  });

  test('nameForFile falls back to the only region in the index', () {
    const tsv =
        'snes\t00000001\tHero Quest (Japan)\n'
        'snes\t00000002\tHero Quest (Japan) (Beta)\n';
    final index = BoxArtIndex.parse(tsv);
    expect(index.nameForFile('snes', 'hero_quest.sfc'), 'Hero Quest (Japan)');
  });

  test('nameForFile matches a hack by its parent title', () {
    const tsv = 'snes\t00000001\tSuper Mario World (USA)\n';
    final index = BoxArtIndex.parse(tsv);
    expect(
      index.nameForFile(
        'snes',
        'Super Mario World - Return to Dinosaur Land.sfc',
      ),
      'Super Mario World (USA)',
    );
  });

  test('a lone word key never matches a longer file name', () {
    const tsv =
        'gba\t00000001\tPokemon Emerald Version (USA)\n'
        'gba\t00000002\tPokemon (USA)\n';
    final index = BoxArtIndex.parse(tsv);
    expect(
      index.nameForFile('gba', 'Pokemon Radical Red.gba'),
      isNot('Pokemon (USA)'),
    );
  });

  test('nameForFile fuzzy-matches a near-miss file name', () {
    const tsv = 'gba\t00000001\tLegend of Zelda, The - The Minish Cap (USA)\n';
    final index = BoxArtIndex.parse(tsv);
    expect(
      index.nameForFile('gba', 'Legend of Zelda Minish Cap.gba'),
      'Legend of Zelda, The - The Minish Cap (USA)',
    );
  });

  test('the bundled index resolves known PS1 and PSP CRCs', () async {
    final index = await BoxArtIndex.load();
    expect(index.nameFor('psx', '41b5f211'), 'Crash Bandicoot (USA)');
    expect(
      index.nameFor('psp', '3348b8a2'),
      'Lumines - Puzzle Fusion (USA) (En,Ja)',
    );
  });

  test('the bundled index resolves PSP discs by serial and name', () async {
    final index = await BoxArtIndex.load();
    expect(
      index.nameForFile('psp', 'PoPoLoCrois [ULUS-10018].cso'),
      'PoPoLoCrois (USA)',
    );
    expect(index.nameForFile('psp', 'popolocrois.iso'), 'PoPoLoCrois (USA)');
  });

  test('titleKey folds accents', () {
    expect(titleKey('Pokémon Émeraude.gba'), 'pokemon emeraude');
  });

  test('the bundled index resolves romhacks to their base game', () async {
    final index = await BoxArtIndex.load();
    const emerald = 'Pokemon - Emerald Version (USA, Europe)';
    for (final f in [
      'Pokemon Emerald Seaglass.gba',
      'Pokémon Emerald Seaglass v3.0.gba',
      'pokemon_seaglass_3.0.gba',
      'Pokemon Inclement Emerald (Hack).gba',
      'Pokemon Emerald Kaizo.gba',
      'Pokemon Emerald Something New.gba',
    ]) {
      expect(index.nameForFile('gba', f), emerald, reason: f);
    }
    for (final f in [
      'Pokemon Unbound.gba',
      'Pokemon Unbound v2.1.1.gba',
      'Pokemon Radical Red 4.1.gba',
      'Pokémon - Radical Red (FireRed Hack).gba',
      'Pokemon Gaia v3.2.gba',
    ]) {
      expect(
        index.nameForFile('gba', f),
        startsWith('Pokemon - FireRed Version'),
        reason: f,
      );
    }
    for (final f in [
      'Pokemon Polished Crystal 3.0.0.gbc',
      'polishedcrystal-3.0.0.gbc',
      'Pokémon Polished Crystal.gbc',
      'Pokemon Crystal Clear v2.gbc',
      'Pokemon Prism.gbc',
    ]) {
      expect(
        index.nameForFile('gbc', f),
        startsWith('Pokemon - Crystal Version'),
        reason: f,
      );
    }
    expect(
      index.nameForFile('gba', 'Pokemon - Emerald Version (USA, Europe).gba'),
      emerald,
    );
    expect(
      index.nameForFile('gbc', 'Pokemon - Crystal Version (USA).gbc'),
      'Pokemon - Crystal Version (USA)',
    );
  });

  test('romhackFor knows hacks by name and only on their system', () {
    expect(romhackFor('gbc', 'Pokemon Polished Crystal.gbc'), isNotNull);
    expect(romhackFor('gba', 'Pokemon Polished Crystal.gbc'), isNull);
    expect(romhackFor('gbc', 'Pokemon Crystal (USA).gbc'), isNull);
    expect(romhackFor('gba', 'Pokemon Emerald (USA).gba'), isNull);
    expect(
      romhackFor('gba', 'Pokemon Blazed Glazed.gba')!.art.first,
      'Pokemon - Blazed Glazed Version (Hack)',
    );
    expect(looksLikeHack('Super Mario World (Hack).sfc'), isTrue);
    expect(looksLikeHack('smw_kaizo.sfc'), isTrue);
    expect(looksLikeHack('Shackled.gba'), isFalse);
  });

  group('cache', () {
    late Directory dir;
    late List<Uri> fetched;
    List<int>? reply;
    var now = DateTime(2026, 10, 1);

    BoxArtCache cache() => BoxArtCache(
      dir.path,
      loadIndex: () async =>
          BoxArtIndex.parse('gba\tcaf2e99f\tAgent Game (USA)\n'),
      fetch: (url) async {
        fetched.add(url);
        return reply;
      },
      clock: () => now,
    );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('dena_art');
      fetched = [];
      reply = coverPng;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('downloads once, then serves the cached file', () async {
      final c = cache();
      final f = await c.coverFor(game());
      expect(f!.readAsBytesSync(), coverPng);
      expect(fetched.single.pathSegments.last, 'Agent Game (USA).png');
      await c.coverFor(game());
      expect(fetched, hasLength(1));
    });

    test('a miss is remembered until the retry period passes', () async {
      reply = null;
      final c = cache();
      expect(await c.coverFor(game()), isNull);
      expect(await c.coverFor(game()), isNull);
      expect(fetched, hasLength(1));
      now = now.add(const Duration(days: 8));
      reply = coverPng;
      // The marker's mtime is the real clock; move it back instead.
      File(p.join(dir.path, 'art', 'abc.none'))
          .setLastModifiedSync(DateTime(2026, 10, 1));
      expect(await c.coverFor(game()), isNotNull);
      expect(fetched, hasLength(2));
    });

    test('unknown CRCs never hit the network', () async {
      expect(
        await cache().coverFor(
          game(crc: '12345678', fileName: 'zzz.gba', title: 'Nothing Here'),
        ),
        isNull,
      );
      expect(fetched, isEmpty);
    });

    test('custom covers win and are removed with the game', () async {
      final c = cache();
      final img = File(p.join(dir.path, 'mine.jpg'))
        ..writeAsBytesSync(coverPng);
      final stored = await c.storeCustom(game(), img);
      final f = await c.coverFor(game(custom: stored));
      expect(f!.path, stored);
      expect(fetched, isEmpty);
      await c.coverFor(game());
      await c.forget(game());
      expect(Directory(p.join(dir.path, 'art')).listSync(), isEmpty);
    });

    test('an unknown CRC falls back to the file name', () async {
      final c = cache();
      final f = await c.coverFor(
        game(crc: '12345678', fileName: 'Agent Game (USA).gba'),
      );
      expect(f, isNotNull);
      expect(fetched.single.pathSegments.last, 'Agent Game (USA).png');
    });

    test('the cache tries every region in the index in order', () async {
      final c = BoxArtCache(
        dir.path,
        loadIndex: () async => BoxArtIndex.parse(
          'gba\t00000001\tAgent Game (USA)\n'
          'gba\t00000002\tAgent Game (Europe)\n',
        ),
        fetch: (url) async {
          fetched.add(url);
          return url.pathSegments.last == 'Agent Game (USA).png'
              ? null
              : coverPng;
        },
        clock: () => now,
      );
      final f = await c.coverFor(
        game(crc: '12345678', fileName: 'agent_game.gba'),
      );
      expect(f!.readAsBytesSync(), coverPng);
      expect(fetched.map((u) => u.pathSegments.last), [
        'Agent Game (USA).png',
        'Agent Game (Europe).png',
      ]);
    });

    test('an old empty miss marker is ignored and rewritten', () async {
      Directory(p.join(dir.path, 'art')).createSync(recursive: true);
      final none = File(p.join(dir.path, 'art', 'abc.none'))
        ..writeAsStringSync('');
      reply = null;
      final c = cache();
      expect(await c.coverFor(game()), isNull);
      expect(fetched, hasLength(1));
      expect(none.readAsStringSync(), BoxArtCache.matcherVersion);
    });

    test('the library title is tried as a query', () async {
      final c = cache();
      final f = await c.coverFor(
        game(crc: '12345678', fileName: 'zzz.gba', title: 'Agent Game'),
      );
      expect(f, isNotNull);
      expect(fetched.single.pathSegments.last, 'Agent Game (USA).png');
    });

    test(
      'a failed download is not remembered and is retried on a new cache',
      () async {
        final c = BoxArtCache(
          dir.path,
          loadIndex: () async =>
              BoxArtIndex.parse('gba\tcaf2e99f\tAgent Game (USA)\n'),
          fetch: (url) async {
            fetched.add(url);
            throw const SocketException('offline');
          },
          clock: () => now,
        );
        expect(await c.coverFor(game()), isNull);
        expect(File(p.join(dir.path, 'art', 'abc.none')).existsSync(), isFalse);
        expect(await c.coverFor(game()), isNull);
        expect(fetched, hasLength(1));
        final f = await cache().coverFor(game());
        expect(f, isNotNull);
        expect(fetched, hasLength(2));
      },
    );

    BoxArtCache pokemonCache() => BoxArtCache(
      dir.path,
      loadIndex: () async => BoxArtIndex.parse(
        'gba\t1f1c08fb\tPokemon - Emerald Version (USA, Europe)\n'
        'gbc\t00000001\tPokemon - Crystal Version (USA)\n',
      ),
      fetch: (url) async {
        fetched.add(url);
        return reply;
      },
      clock: () => now,
    );

    test(
      'a hack with no art of its own gets its base cover and a badge',
      () async {
        final c = pokemonCache();
        final g = game(
          crc: '12345678',
          fileName: 'Pokemon Emerald Seaglass.gba',
          title: 'Pokemon Emerald Seaglass',
        );
        expect(await c.coverFor(g), isNotNull);
        expect(
          fetched.single.pathSegments.last,
          'Pokemon - Emerald Version (USA, Europe).png',
        );
        expect(await c.isHackStandIn(g), isTrue);

        final crystal = game(
          sha1: 'def',
          system: 'gbc',
          crc: '12345678',
          fileName: 'polishedcrystal-3.0.0.gbc',
          title: 'polishedcrystal-3.0.0',
        );
        expect(await c.coverFor(crystal), isNotNull);
        expect(
          fetched.last.pathSegments.last,
          'Pokemon - Crystal Version (USA).png',
        );
        expect(await c.isHackStandIn(crystal), isTrue);
      },
    );

    test('a hack\'s own art is tried first and has no badge', () async {
      final c = BoxArtCache(
        dir.path,
        loadIndex: () async => BoxArtIndex.parse(
          'gba\t1f1c08fb\tPokemon - Emerald Version (USA, Europe)\n',
        ),
        fetch: (url) async {
          fetched.add(url);
          return url.pathSegments.last.contains('Hack') ? coverPng : null;
        },
        clock: () => now,
      );
      final g = game(crc: '12345678', fileName: 'Pokemon Glazed.gba');
      expect(await c.coverFor(g), isNotNull);
      expect(
        fetched.single.pathSegments.last,
        'Pokemon - Glazed Version (Hack).png',
      );
      expect(await c.isHackStandIn(g), isFalse);
    });

    test('a CRC match is never badged', () async {
      final c = pokemonCache();
      final g = game(crc: '1f1c08fb', fileName: 'Pokemon Emerald (Hack).gba');
      expect(await c.coverFor(g), isNotNull);
      expect(await c.isHackStandIn(g), isFalse);
    });

    test('a PICO-8 cart is its own cover', () async {
      final cart = File(p.join(dir.path, 'cart.p8.png'))
        ..writeAsBytesSync(coverPng);
      final f = await cache().coverFor(
        game(system: 'pico8', fileName: 'cart.p8.png', path: cart.path),
      );
      expect(f!.path, cart.path);
      expect(fetched, isEmpty);
    });

    test('prefetch downloads in the background and warms the cache', () async {
      final c = cache();
      c.prefetch([game()]);
      final file = File(p.join(dir.path, 'art', 'abc.png'));
      for (var i = 0; i < 100 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(file.existsSync(), isTrue);
      expect(fetched, hasLength(1));
      await c.coverFor(game());
      expect(fetched, hasLength(1));
    });
  });

  testScreens(
    'game card with a cover',
    (tester, screen, mode) async {
      final dir = Directory.systemTemp.createTempSync('dena_art_card');
      addTearDown(() => dir.deleteSync(recursive: true));
      final db = (await tester.runAsync(() => seededDb([])))!;
      final art = BoxArtCache(
        dir.path,
        loadIndex: () async => BoxArtIndex.parse('gba\tcaf2e99f\tAgent Game\n'),
        fetch: (_) async => coverPng,
      );
      final g = game();
      // Warm the cache outside the fake clock.
      await tester.runAsync(() => art.coverFor(g));
      await tester.pumpWidget(
        LibraryScope(
          db: db,
          importer: Importer(db, dir),
          files: FakeFiles(),
          art: art,
          child: DenaApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 160,
                  height: 220,
                  child: GameCard(game: g, onPlay: () {}, onDetails: (_) {}),
                ),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      expect(find.byType(Image), findsOneWidget);
      await expectLater(
        find.byType(DenaApp),
        matchesGoldenFile(goldenName('game_card_cover', screen, mode)),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      await tester.runAsync(db.close);
    },
    sizes: const [phone],
    modes: const [InputMode.touch],
  );
}
