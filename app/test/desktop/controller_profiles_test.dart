// Controller profiles on Windows and SteamOS: precedence, the host text,
// the database, the store and the Brutalist settings pages.
// Spec: docs/specs/gamepads.md (Desktop: profiles and gyro)
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/desktop/controller_profiles.dart';
import 'package:dena_emu/src/desktop/controller_profiles_page.dart';
import 'package:dena_emu/src/desktop/tv_layout.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _xbox = '030000005e040000e002000000000000';
const _deck = '0300000028de00000512000000000000';
const _zelda = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _mario = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class FakeProfilesHost implements ProfilesHost {
  FakeProfilesHost([this.connected = const []]);

  final List<ConnectedPad> connected;
  final sent = <String>[];

  @override
  void setProfiles(String text) => sent.add(text);

  @override
  List<ConnectedPad> pads() => connected;
}

const _pads = [
  ConnectedPad(port: 0, guid: _deck, gyro: true, name: 'Steam Deck'),
  ConnectedPad(port: 1, guid: _xbox, gyro: false, name: 'Xbox Controller'),
];

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await load(brutalMono, [
    for (final w in ['Medium', 'SemiBold', 'Bold'])
      'assets/fonts/ibm_plex_mono/IBMPlexMono-$w.ttf',
  ]);
  await load(brutalDisplay, [
    'assets/fonts/archivo_black/ArchivoBlack-Regular.ttf',
  ]);
  await load('DenaIcons', ['assets/fonts/dena_icons/DenaIcons.otf']);
}

Future<List<ProfileGame>> _games() async => [
  (sha1: _zelda, title: 'Zelda Homebrew'),
  (sha1: _mario, title: 'Kart Demo'),
];

void main() {
  group('precedence', () {
    const anyAny = ControllerProfile(id: 1);
    const xboxAny = ControllerProfile(id: 2, controller: _xbox);
    const anyZelda = ControllerProfile(id: 3, game: _zelda);
    const xboxZelda = ControllerProfile(id: 4, controller: _xbox, game: _zelda);
    const all = [anyAny, xboxAny, anyZelda, xboxZelda];

    test('this controller in this game wins, then any controller in this '
        'game, then this controller, then any', () {
      expect(resolveProfile(all, controller: _xbox, game: _zelda), xboxZelda);
      expect(resolveProfile(all, controller: _deck, game: _zelda), anyZelda);
      expect(resolveProfile(all, controller: _xbox, game: _mario), xboxAny);
      expect(resolveProfile(all, controller: _xbox), xboxAny);
      expect(resolveProfile(all, controller: _deck, game: _mario), anyAny);
      expect(resolveProfile(all, controller: ''), anyAny);
    });

    test('a game\'s profile beats a controller\'s', () {
      expect(
        resolveProfile([xboxAny, anyZelda], controller: _xbox, game: _zelda),
        anyZelda,
      );
    });

    test('no profile: the pad plays as is', () {
      expect(resolveProfile(const [], controller: _xbox), isNull);
      expect(
        resolveProfile([xboxZelda], controller: _xbox, game: _mario),
        isNull,
      );
    });
  });

  group('host text', () {
    test('a line per named controller and * for the rest', () {
      final all = [
        const ControllerProfile(id: 1, gyro: GyroMode.leftStick),
        ControllerProfile(
          id: 2,
          controller: _xbox,
          game: _zelda,
          buttons: [...identityButtons]
            ..[0] = 8
            ..[8] = 0,
        ),
        const ControllerProfile(
          id: 3,
          controller: _deck,
          gyro: GyroMode.pointer,
          sensitivity: 1.5,
          deadzone: 3,
          invertY: true,
        ),
      ];
      expect(
        profilesText(all, game: _zelda, system: 'nds'),
        '$_deck map=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 gyro=3 sens=150 '
        'dz=300 inv=1 area=1\n'
        '$_xbox map=8,1,2,3,4,5,6,7,0,9,10,11,12,13,14,15 gyro=0 sens=100 '
        'dz=150 inv=0 area=1\n'
        '* map=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 gyro=1 sens=100 '
        'dz=150 inv=0 area=1\n',
      );
      // Outside Zelda the Xbox falls back to "*"; not a DS: whole frame.
      expect(
        profilesText(all, game: _mario, system: 'psp'),
        '$_deck map=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 gyro=3 sens=150 '
        'dz=300 inv=1 area=0\n'
        '* map=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 gyro=1 sens=100 '
        'dz=150 inv=0 area=0\n',
      );
      expect(profilesText(const []), '');
    });

    test('defaults: gyro off, x1, 1.5 deg/s, not inverted, identity', () {
      const p = ControllerProfile();
      expect(p.gyro, GyroMode.off);
      expect((p.sensitivity, p.deadzone, p.invertY), (1.0, 1.5, false));
      expect(p.remapped, 0);
      expect(gyroSensitivities, contains(p.sensitivity));
      expect(gyroDeadzones, contains(p.deadzone));
    });
  });

  test('pads info parses by port, waiting pads last', () {
    final pads = ConnectedPad.parse(
      '-1\tguid9\t0\tNinth Pad\n'
      '1\t$_xbox\t0\tXbox Controller\n'
      '0\t$_deck\t1\tSteam\tDeck\n'
      'junk\n'
      '2\t\t0\tno guid\n',
    );
    expect(pads.map((p) => p.port), [0, 1, -1]);
    expect(pads.first.name, 'Steam\tDeck');
    expect(pads.first.gyro, isTrue);
    expect(pads[1].gyro, isFalse);
  });

  group('database and store', () {
    late ProfilesDatabase db;
    setUp(() => db = ProfilesDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('saves, replaces the same controller and game, removes', () async {
      final id = await db.put(
        const ControllerProfile(controller: _xbox, gyro: GyroMode.rightStick),
      );
      final again = await db.put(
        const ControllerProfile(controller: _xbox, invertY: true),
      );
      expect(again, isNot(id));
      var all = await db.all();
      expect(all, hasLength(1));
      expect(all.single.invertY, isTrue);
      expect(all.single.gyro, GyroMode.off);
      // Editing by id keeps the id; moving it onto another profile's
      // controller and game replaces that one.
      final other = await db.put(const ControllerProfile(game: _zelda));
      await db.put(all.single.copyWith(controller: '', game: _zelda));
      all = await db.all();
      expect(all.map((p) => p.id), [again]);
      expect(all.single.anyController, isTrue);
      expect(other, isNot(again));
      await db.remove(again);
      expect(await db.all(), isEmpty);
    });

    test('the store sends the profiles for the game playing now', () async {
      final host = FakeProfilesHost();
      final store = ControllerProfileStore(db: db, host: host);
      await store.load();
      expect(host.sent, ['']);
      final saved = await store.save(
        const ControllerProfile(game: _zelda, gyro: GyroMode.leftStick),
      );
      expect(saved.id, isNotNull);
      expect(host.sent.last, ''); // not playing Zelda
      store.applyGame(_zelda, 'n64');
      expect(host.sent.last, startsWith('* '));
      expect(host.sent.last, contains('gyro=1'));
      store.applyGame('', '');
      expect(host.sent.last, '');
      await store.save(saved.copyWith(game: ''));
      expect(store.profiles, hasLength(1));
      expect(host.sent.last, contains('gyro=1'));
      await store.remove(store.profiles.single);
      expect(store.profiles, isEmpty);
      expect(host.sent.last, '');
      // A fresh store reads what was saved.
      await store.save(const ControllerProfile(controller: _deck));
      final fresh = ControllerProfileStore(db: db);
      await fresh.load();
      expect(fresh.profiles.single.controller, _deck);
    });
  });

  group('pages', () {
    setUpAll(_loadFonts);

    Widget app(Widget home, {bool tv = false}) => TvScale(
      enabled: tv,
      child: DenaApp(home: home),
    );

    Future<ControllerProfileStore> seeded() async {
      final store = ControllerProfileStore(host: FakeProfilesHost(_pads));
      await store.save(
        const ControllerProfile(
          controller: _deck,
          controllerName: 'Steam Deck',
          game: _zelda,
          gameTitle: 'Zelda Homebrew',
          gyro: GyroMode.pointer,
          sensitivity: 1.5,
        ),
      );
      await store.save(
        ControllerProfile(
          controller: _xbox,
          controllerName: 'Xbox Controller',
          buttons: [...identityButtons]
            ..[0] = 8
            ..[8] = 0,
        ),
      );
      return store;
    }

    testWidgets('the settings row counts the profiles and opens the page', (
      tester,
    ) async {
      final store = (await tester.runAsync(seeded))!;
      await tester.pumpWidget(
        app(Scaffold(body: ControllerProfilesTile(store: store))),
      );
      expect(find.text('2 saved >'), findsOneWidget);
      await tester.tap(find.text('PROFILES'));
      await tester.pumpAndSettle();
      expect(find.byType(ControllerProfilesPage), findsOneWidget);
      expect(find.text('Steam Deck'), findsNWidgets(2)); // saved + connected
      expect(find.text('Pointer x1.5'), findsOneWidget);
    });

    testWidgets('D-pad: new profile, gyro to L-stick, remap A to B', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = ControllerProfileStore(host: FakeProfilesHost(_pads));
      await tester.pumpWidget(
        app(ControllerProfilesPage(store: store, games: _games)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('> No profiles yet: every pad plays as is.'),
        findsOneWidget,
      );
      // New profile has focus.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(find.byType(ControllerProfileEditor), findsOneWidget);
      // Controller (focused) > Steam Deck.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(find.byType(ProfileChoicePage<(String, String)>), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pumpAndSettle();
      expect(store.profiles.single.controller, _deck);
      expect(store.profiles.single.controllerName, 'Steam Deck');
      // Game by tap: Zelda.
      await tester.tap(find.text('GAME'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zelda Homebrew'));
      await tester.pumpAndSettle();
      expect(store.profiles.single.game, _zelda);
      // Gyro by tap.
      await tester.tap(find.text(' L-STICK '));
      await tester.pumpAndSettle();
      expect(store.profiles.single.gyro, GyroMode.leftStick);
      await tester.tap(find.text(' X2 '));
      await tester.pumpAndSettle();
      expect(store.profiles.single.sensitivity, 2.0);
      // A sends B.
      await tester.ensureVisible(find.text('A').first);
      await tester.tap(find.text('A').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(store.profiles.single.buttons[8], 0);
      expect(store.profiles.single.remapped, 1);
      expect(find.text('-> B'), findsOneWidget);
      // Back to the list: one row.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await tester.pumpAndSettle();
      expect(find.text('L-stick x2'), findsOneWidget);
    });

    testWidgets('holding delete removes the profile', (tester) async {
      final store = (await tester.runAsync(seeded))!;
      await tester.pumpWidget(
        app(
          ControllerProfileEditor(store: store, profile: store.profiles.first),
        ),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('HOLD TO DELETE')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.profiles, hasLength(1));
    });

    for (final (name, size, tv) in [
      ('1280x720', const Size(1280, 720), false),
      ('tv_1920x1080', const Size(1920, 1080), true),
    ]) {
      testWidgets('golden: profiles list and editor at $name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final store = (await tester.runAsync(seeded))!;
        await tester.pumpWidget(
          app(
            ControllerProfilesPage(store: store, games: _games),
            tv: tv,
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(DenaApp),
          matchesGoldenFile('goldens/controller_profiles_$name.png'),
        );
        await tester.tap(find.text('Zelda Homebrew'));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(DenaApp),
          matchesGoldenFile('goldens/controller_profile_editor_$name.png'),
        );
      });
    }
  });
}
