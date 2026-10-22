// Spec: docs/specs/open-with.md
import 'dart:io';

import 'package:dena_emu/src/desktop/open_with.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/fake_roms.dart';

import '../support/library_fixture.dart';

void main() {
  group('gameArgument', () {
    test('is the first argument that is not a flag', () {
      expect(gameArgument([]), isNull);
      expect(gameArgument(['--verbose']), isNull);
      expect(
        gameArgument(['--fullscreen', r'C:\Games\Alpha.gba', 'b.nes']),
        r'C:\Games\Alpha.gba',
      );
      expect(
        gameArgument(['', '/home/deck/Beta Racer.nes']),
        '/home/deck/Beta Racer.nes',
      );
    });

    test('turns file URIs into paths', () {
      expect(
        gameArgument(['file:///home/deck/Beta%20Racer.nes']),
        '/home/deck/Beta Racer.nes',
      );
    });
  });

  group('OpenedFiles', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('dena/window_test');

    test(
      'queues the launch file, then each file a second launch sends',
      () async {
        final opened = OpenedFiles(initial: 'a.gba', channel: channel);
        var heard = 0;
        opened.addListener(() => heard++);
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              channel.name,
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('openFile', 'b.nes'),
              ),
              (_) {},
            );
        expect(heard, 1);
        expect(opened.take(), 'a.gba');
        expect(opened.take(), 'b.nes');
        expect(opened.take(), isNull);
      },
    );
  });

  group('openGameFile', () {
    late Directory tmp;
    late LibraryDatabase db;
    late Importer importer;

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      tmp = await Directory.systemTemp.createTemp('dena_open');
      db = LibraryDatabase(NativeDatabase.memory());
      importer = Importer(db, Directory(p.join(tmp.path, 'data', 'games')));
    });
    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    File rom(String rel, int fill) =>
        File(p.joinAll([tmp.path, ...rel.split('/')]))
          ..createSync(recursive: true)
          ..writeAsBytesSync(fakeRom(rel, fill: fill));

    test('adds only that file, in place, and opens it', () async {
      final f = rom('Downloads/Alpha Quest (USA).nes', 1);
      rom('Downloads/Beta Racer.gba', 2);
      final r = await openGameFile(f.path, db: db, importer: importer);
      final game = (r as OpenedGame).game;
      expect(game.path, f.path);
      expect(game.system, 'nes');
      expect(await db.allGames(), hasLength(1), reason: 'not its folder');
      expect(
        Directory(importer.gamesDir.path).existsSync(),
        isFalse,
        reason: 'no copy',
      );
    });

    test('a game already in the library opens that game', () async {
      final f = rom('Games/Alpha.nes', 1);
      final first = await openGameFile(f.path, db: db, importer: importer);
      final again = await openGameFile(f.path, db: db, importer: importer);
      expect((again as OpenedGame).game.id, (first as OpenedGame).game.id);
      final copy = rom('Elsewhere/Alpha copy.nes', 1);
      final dup = await openGameFile(copy.path, db: db, importer: importer);
      expect((dup as OpenedGame).game.id, first.game.id);
      expect(await db.allGames(), hasLength(1));
    });

    test('a relative path resolves from the working folder', () async {
      final f = rom('Alpha.gba', 3);
      final old = Directory.current;
      Directory.current = tmp;
      try {
        final r = await openGameFile('Alpha.gba', db: db, importer: importer);
        expect(p.equals((r as OpenedGame).game.path, f.path), isTrue);
      } finally {
        Directory.current = old;
      }
    });

    test('a missing or unsupported file says why', () async {
      final missing = await openGameFile(
        p.join(tmp.path, 'Gone.nes'),
        db: db,
        importer: importer,
      );
      expect((missing as OpenFailed).message, 'Could not find Gone.nes');
      final txt = File(p.join(tmp.path, 'notes.txt'))..writeAsStringSync('hi');
      final bad = await openGameFile(txt.path, db: db, importer: importer);
      expect((bad as OpenFailed).message, startsWith('notes.txt: '));
      final renamed = File(p.join(tmp.path, 'notes.nes'))
        ..writeAsStringSync('hi, not a game');
      final fake = await openGameFile(renamed.path, db: db, importer: importer);
      expect(
        (fake as OpenFailed).message,
        'notes.nes: Not a supported game file',
      );
      expect(await db.allGames(), isEmpty);
    });
  });

  group('the shell', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dena_open_shell'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> settleIo(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    }

    testWidgets('plays the launch file, then a file a second launch opens', (
      tester,
    ) async {
      played = [];
      final db = await tester.runAsync(() => seededDb(['Alpha Quest']));
      final a = File(p.join(tmp.path, 'Delta Dash.gba'))
        ..writeAsBytesSync(fakeRom('a.gba', fill: 7));
      final opened = OpenedFiles(initial: a.path, channel: null);
      await tester.pumpWidget(shellApp(db!, opened: opened));
      await settleIo(tester);
      expect(played.single.title, 'Delta Dash');
      expect(played.single.path, a.path);

      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(MaterialPageRoute<void>(builder: (_) => const Text('sheet')));
      await settleIo(tester);
      opened.add(p.join(tmp.path, 'missing.nes'));
      await settleIo(tester);
      expect(find.text('Could not find missing.nes'), findsOneWidget);
      expect(find.text('sheet'), findsOneWidget, reason: 'failures stay put');

      opened.add(a.path);
      await settleIo(tester);
      expect(played, hasLength(2));
      expect(find.text('sheet'), findsNothing, reason: 'back to the library');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      await tester.runAsync(db.close);
    });
  });
}
