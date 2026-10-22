import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/achievements/achievements_ui.dart';
import 'package:dena_emu/src/achievements/retro_achievements.dart';
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../session_screen_test.dart'
    show FakeGameApi, closeDb, firstGame, sessionApp;
import '../support/library_fixture.dart' show seededDb;
import 'fake_ra_native.dart';

Game game({String system = 'gba'}) => Game(
  id: 1,
  system: system,
  title: 'Test Game',
  searchTitle: 'test game',
  fileName: 'test.gba',
  path: '/games/test.gba',
  sha1: 'sha0',
  size: 1,
  crc32: '0',
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
);

Directory tempDir() => Directory.systemTemp.createTempSync('dena_ra');

RetroAchievements signedIn(FakeRaNative native, Directory dir) {
  File(p.join(dir.path, 'retroachievements.json')).writeAsStringSync(
    jsonEncode({'account': FakeRaNative.account, 'hardcore': true}),
  );
  return RetroAchievements(native: native, dataDir: dir.path);
}

/// Lets the 100 ms pump timer run until nothing is pending.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void main() {
  group('RetroAchievements', () {
    test('sign in keeps the token, never the password', () async {
      final dir = tempDir();
      final native = FakeRaNative();
      final ra = RetroAchievements(native: native, dataDir: dir.path);
      expect(await ra.signIn('tester', 'nope'), contains('Invalid'));
      expect(ra.account, isNull);
      expect(await ra.signIn(' tester ', 'secret'), isNull);
      expect(ra.account?.name, 'Tester');
      expect(native.calls, contains('login tester password'));
      final saved = File(p.join(dir.path, 'retroachievements.json'))
          .readAsStringSync();
      expect(saved, contains('"token":"tok"'));
      expect(saved, isNot(contains('secret')));
      ra.signOut();
      expect(ra.account, isNull);
      ra.dispose();
    });

    test('a rejected token signs out; hardcore persists', () async {
      final dir = tempDir();
      final native = FakeRaNative()..tokenValid = false;
      final ra = signedIn(native, dir);
      expect(native.calls, ['hardcore true']);
      ra.hardcore = false;
      await expectLater(
        ra.fetchGame('/games/test.gba', 'gba'),
        throwsA(isA<RaFetchError>()),
      );
      expect(ra.account, isNull);
      final again = RetroAchievements(native: native, dataDir: dir.path);
      expect(again.hardcore, isFalse);
      ra.dispose();
      again.dispose();
    });

    test('requests go out over HTTP and responses come back', () async {
      final native = FakeRaNative()
        ..requests.add({
          'id': 3,
          'url': 'https://retroachievements.org/dorequest.php',
          'post': 'r=ping',
          'type': 'application/x-www-form-urlencoded',
        });
      String? agent, post;
      final ra = RetroAchievements(
        native: native,
        dataDir: tempDir().path,
        appVersion: '1.2.3',
        http: (url, body, type, ua) async {
          agent = ua;
          post = body;
          return (200, utf8.encode('{"Success":true}'));
        },
      );
      await ra.signIn('tester', 'secret');
      await Future<void>.delayed(Duration.zero);
      expect(post, 'r=ping');
      expect(agent, startsWith('Dena.emu/1.2.3 ('));
      expect(agent, endsWith('rcheevos/12.5'));
      expect(native.responses.single, (3, 200, '{"Success":true}'));
      ra.dispose();
    });

    test('game page list, PICO-8 has none', () async {
      final native = FakeRaNative();
      final ra = signedIn(native, tempDir());
      final info = await ra.fetchGame('/games/test.gba', 'gba');
      expect(info.unlocked, 1);
      expect(info.points, 15);
      expect(info.achievements.first.unlock, RaUnlock.hardcore);
      expect(native.calls, contains('fetch /games/test.gba 5'));
      expect(ra.supports('pico8'), isFalse);
      expect(ra.hardcoreFor('gba'), isTrue);
      ra.dispose();
    });
  });

  testWidgets('settings: sign in, then hardcore switch', (tester) async {
    final native = FakeRaNative();
    final ra = RetroAchievements(native: native, dataDir: tempDir().path);
    await tester.pumpWidget(DenaApp(home: RetroAchievementsPage(ra: ra)));
    await tester.enterText(
      find.widgetWithText(TextField, 'USERNAME'),
      'tester',
    );
    await tester.enterText(find.widgetWithText(TextField, 'PASSWORD'), 'bad');
    await tester.tap(find.widgetWithText(BrutalButton, '[SIGN IN]'));
    await settle(tester);
    expect(find.textContaining('Invalid user/password'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'PASSWORD'),
      'secret',
    );
    await tester.tap(find.widgetWithText(BrutalButton, '[SIGN IN]'));
    await settle(tester);
    expect(find.text('Tester'), findsOneWidget);
    expect(find.textContaining('120 hardcore points'), findsOneWidget);
    expect(find.text('[ONLINE]'), findsOneWidget);
    await tester.tap(find.widgetWithText(CfgToggle, '[ON]'));
    await tester.pump();
    expect(ra.hardcore, isFalse);
    expect(find.widgetWithText(CfgToggle, '[OFF]'), findsOneWidget);
    ra.dispose();
  });

  testWidgets('game page lists achievements, unlocked first', (tester) async {
    final ra = signedIn(FakeRaNative(), tempDir());
    await tester.pumpWidget(
      DenaApp(
        home: GameAchievementsPage(ra: ra, game: game()),
      ),
    );
    await settle(tester);
    expect(find.text('1 of 2 unlocked'), findsOneWidget);
    expect(find.textContaining('5 of 15 points'), findsOneWidget);
    expect(find.textContaining('Unlocked in hardcore'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('FIRST')).dy,
      lessThan(tester.getTopLeft(find.text('SECOND')).dy),
    );
    ra.dispose();
  });

  testWidgets('hardcore session: no resume, no Load/Rewind/Cheats, toast', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    final native = FakeRaNative();
    final ra = signedIn(native, tempDir());
    final api = FakeGameApi();
    final db = (await tester.runAsync(() => seededDb(['Pocket: Quest'])))!;
    final g = await firstGame(tester, db);
    await tester.pumpWidget(sessionApp(db, g, api, achievements: ra));
    await tester.tap(find.text('library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      api.calls.skipWhile((c) => c.startsWith('latency ')).first,
      endsWith('sha0.srm '),
    ); // no auto-save state
    expect(native.calls, contains('begin /nowhere/0 5'));
    expect(
      find.text('1 of 2 achievements unlocked · Hardcore'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('SAVE STATE'), findsOneWidget);
    expect(find.text('LOAD STATE'), findsNothing);
    expect(find.text('REWIND'), findsNothing);
    expect(find.text('CHEATS'), findsNothing);
    expect(find.text('[1/2]'), findsOneWidget);
    await tester.tap(find.text('ACHIEVEMENTS'));
    await tester.pumpAndSettle();
    expect(find.text('3/10'), findsNothing); // progress shows under the title
    expect(find.textContaining('3/10'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(find.text('QUIT GAME'));
    await tester.pumpAndSettle();
    expect(native.calls.last, 'end');
    expect(api.calls.last, 'stop');
    await settle(tester);
    ra.dispose();
    await closeDb(tester, db);
  });
}
