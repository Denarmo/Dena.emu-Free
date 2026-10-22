// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/file-explorer.md
import 'dart:io';

import 'package:dena_emu/src/library/file_explorer.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/dena_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';

/// Lets real file I/O finish, then rebuilds: waits while the explorer shows
/// its spinner.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (i > 15 && find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late Directory tmp;
  List<String>? lastResult;

  setUp(() => tmp = Directory.systemTemp.createTempSync('explorer'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void touch(String rel) => (File(
    p.join(tmp.path, rel),
  )..createSync(recursive: true)).writeAsStringSync('x');

  group('removableMounts', () {
    const mounts = '''
/dev/mmcblk0p2 / ext4 ro 0 0
/dev/mmcblk0p1 /boot vfat rw 0 0
proc /proc proc rw 0 0
/dev/mmcblk0p4 /mnt/card exfat rw 0 0
/dev/sda1 /media/usb\\040stick vfat rw 0 0
/dev/mmcblk1p1 /mnt/sdcard2 vfat rw 0 0
tmpfs /run tmpfs rw 0 0
''';

    test('keeps USB and second-card mounts, drops system and the card', () {
      expect(removableMounts(mounts, exclude: '/mnt/card').map((m) => m.dir), [
        '/media/usb stick',
        '/mnt/sdcard2',
      ]);
    });

    test('handheld roots: card first, opened at Roms, then drives', () async {
      touch('card/Roms/gba/a.gba');
      final card = p.join(tmp.path, 'card');
      final roots = await explorerRoots(
        handheld: true,
        env: {'DENA_CARD': card},
        mounts: '/dev/sda1 /media/usb vfat rw 0 0\n',
      );
      expect(roots.map((r) => r.label), ['Games card', 'USB drive']);
      expect(roots.first.start, p.join(card, 'Roms'));
      expect(roots.last.icon, DenaIcons.usb);
    });

    test('Android fallback roots: shared storage and other volumes', () async {
      Directory(p.join(tmp.path, 'emulated', '0')).createSync(recursive: true);
      Directory(p.join(tmp.path, 'self')).createSync();
      Directory(p.join(tmp.path, '1A2B-3C4D')).createSync();
      final roots = await explorerRoots(handheld: false, storage: tmp);
      expect(roots.map((r) => r.label), ['Internal storage', '1A2B-3C4D']);
    });
  });

  test(
    'listing: folders first, by name, games only unless all files',
    () async {
      touch('b/x.txt');
      touch('A/y.gba');
      touch('zelda.gb');
      touch('Mario.SFC');
      touch('cart.p8.png');
      touch('notes.txt');
      touch('.hidden.gba');
      final names = (await listFolder(
        tmp,
        importExtensions,
      )).map((e) => e.name).toList();
      expect(names, ['A', 'b', 'cart.p8.png', 'Mario.SFC', 'zelda.gb']);
      final all = await listFolder(tmp, importExtensions, allFiles: true);
      expect(all.map((e) => e.name), contains('notes.txt'));
    },
  );

  test('collectGames walks subfolders and keeps only games', () async {
    touch('gba/a.gba');
    touch('gba/deep/b.gba');
    touch('snes/c.sfc');
    touch('snes/readme.txt');
    final games = await collectGames(tmp, importExtensions);
    expect(games.map(p.basename).toSet(), {'a.gba', 'b.gba', 'c.sfc'});
    expect(
      await collectGames(tmp, importExtensions, maxDepth: 1),
      hasLength(2),
    );
    expect(await collectGames(tmp, importExtensions, limit: 1), hasLength(1));
  });

  test('memory remembers the last folder', () async {
    final mem = ExplorerMemory(File(p.join(tmp.path, 'data', 'explorer.json')));
    expect(await mem.last(), isNull);
    await mem.remember('/mnt/card/Roms/gba');
    expect(await mem.last(), '/mnt/card/Roms/gba');
  });

  group('explorer screen', () {
    /// Lets real file I/O finish, then rebuilds.

    Future<void> open(
      WidgetTester tester, {
      required bool folder,
      required List<ExplorerRoot> roots,
      ExplorerMemory? memory,
      bool handheld = true,
    }) async {
      List<String>? result;
      await tester.pumpWidget(
        MaterialApp(
          shortcuts: {
            ...WidgetsApp.defaultShortcuts,
            const SingleActivator(LogicalKeyboardKey.gameButtonB):
                const BackIntent(),
          },
          actions: {
            ...WidgetsApp.defaultActions,
            BackIntent: CallbackAction<BackIntent>(
              onInvoke: (_) => tester
                  .state<NavigatorState>(find.byType(Navigator).first)
                  .maybePop(),
            ),
          },
          builder: (context, child) =>
              Handheld(enabled: handheld, child: child!),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<List<String>>(
                  MaterialPageRoute(
                    builder: (_) => FileExplorerPage(
                      roots: roots,
                      folderMode: folder,
                      extensions: importExtensions,
                      memory: memory,
                    ),
                  ),
                );
                lastResult = result;
              },
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
    }

    testWidgets('Add games: check files with A and add them with Start', (
      tester,
    ) async {
      touch('Roms/gba/a.gba');
      touch('Roms/gba/b.gba');
      touch('Roms/gba/notes.txt');
      final root = ExplorerRoot(
        'Games card',
        tmp.path,
        DenaIcons.sdCard,
        start: p.join(tmp.path, 'Roms'),
      );
      final memory = ExplorerMemory(File(p.join(tmp.path, 'mem.json')));
      await open(tester, folder: false, roots: [root], memory: memory);
      expect(find.text('gba/'), findsOneWidget);
      // A opens the focused folder.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await settle(tester);
      expect(find.text('a.gba'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);
      // A checks the first game, Down + A the second.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await tester.pump();
      expect(find.text('ADD 2 GAMES'), findsOneWidget);
      // Y shows every file.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonY);
      await settle(tester);
      expect(find.text('notes.txt'), findsOneWidget);
      // Start imports; the page pops with both paths.
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonStart);
      await settle(tester);
      expect(find.byType(FileExplorerPage), findsNothing);
      expect(lastResult?.map(p.basename).toSet(), {'a.gba', 'b.gba'});
      expect(
        await tester.runAsync(memory.last),
        p.join(tmp.path, 'Roms', 'gba'),
      );
    });

    testWidgets('phone, touch: tap a folder, tap games, tap ADD', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      touch('ROMS/gba/a.gba');
      touch('ROMS/gba/b.gba');
      touch('ROMS/nes/c.nes');
      final root = ExplorerRoot('Phone storage', tmp.path, DenaIcons.sdCard);
      await open(tester, folder: false, roots: [root], handheld: false);
      await tester.tap(find.text('ROMS/'));
      await settle(tester);
      await tester.tap(find.text('gba/'));
      await settle(tester);
      await tester.tap(find.text('a.gba'));
      await tester.pump();
      await tester.tap(find.text('b.gba'));
      await tester.pump();
      await tester.tap(find.text('ADD 2 GAMES'));
      await settle(tester);
      expect(find.byType(FileExplorerPage), findsNothing);
      expect(lastResult?.map(p.basename).toSet(), {'a.gba', 'b.gba'});
    });

    testWidgets('phone, touch: Add a folder takes the open folder', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      touch('ROMS/gba/a.gba');
      touch('ROMS/nes/c.nes');
      final root = ExplorerRoot('Phone storage', tmp.path, DenaIcons.sdCard);
      await open(tester, folder: true, roots: [root], handheld: false);
      await tester.tap(find.text('ROMS/'));
      await settle(tester);
      await tester.tap(find.text('USE THIS FOLDER'));
      await settle(tester);
      expect(find.byType(FileExplorerPage), findsNothing);
      expect(lastResult?.map(p.basename).toSet(), {'a.gba', 'c.nes'});
    });

    testWidgets('B goes up a level, then closes at the top', (tester) async {
      touch('gba/a.gba');
      final root = ExplorerRoot('Games card', tmp.path, DenaIcons.sdCard);
      await open(tester, folder: false, roots: [root]);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await settle(tester);
      expect(find.text('a.gba'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await settle(tester);
      expect(find.text('gba/'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await settle(tester);
      expect(find.byType(FileExplorerPage), findsNothing);
    });

    testWidgets('several roots: list them, B from a root goes back to it', (
      tester,
    ) async {
      Directory(p.join(tmp.path, 'card')).createSync();
      touch('usb/c.nes');
      await open(
        tester,
        folder: false,
        roots: [
          ExplorerRoot(
            'Games card',
            p.join(tmp.path, 'card'),
            DenaIcons.sdCard,
          ),
          ExplorerRoot('USB drive', p.join(tmp.path, 'usb'), DenaIcons.usb),
        ],
      );
      expect(find.text('USB drive'), findsWidgets);
      await tester.tap(find.text('USB drive'));
      await settle(tester);
      expect(find.text('c.nes'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
      await settle(tester);
      expect(find.text('Games card'), findsWidgets);
      expect(find.byType(FileExplorerPage), findsOneWidget);
    });

    testWidgets('Add a folder: Use this folder returns every game under it', (
      tester,
    ) async {
      touch('gba/a.gba');
      touch('gba/sub/b.gba');
      touch('gba/readme.txt');
      final root = ExplorerRoot('Games card', tmp.path, DenaIcons.sdCard);
      final memory = ExplorerMemory(File(p.join(tmp.path, 'mem.json')));
      await tester.runAsync(() => memory.remember(p.join(tmp.path, 'gba')));
      List<String>? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  picked = await Navigator.of(context).push<List<String>>(
                    MaterialPageRoute(
                      builder: (_) => FileExplorerPage(
                        roots: [root],
                        folderMode: true,
                        extensions: importExtensions,
                        memory: memory,
                      ),
                    ),
                  ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      // Reopened at the remembered folder.
      expect(find.text('sub/'), findsOneWidget);
      await tester.tap(find.text('USE THIS FOLDER'));
      await settle(tester);
      expect(picked?.map(p.basename).toSet(), {'a.gba', 'b.gba'});
    });
  });

  group('pickGamePaths', () {
    Future<(List<String>, List<bool>)> pick(
      WidgetTester tester,
      FakeFiles files, {
      required bool folder,
    }) async {
      final explorerCalls = <bool>[];
      // Filled when the pick finishes, which may be after a dialog.
      final paths = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => paths.addAll(
                await pickGamePaths(
                  context,
                  files,
                  folder: folder,
                  explorer: (_, {required folder, required extensions}) async {
                    explorerCalls.add(folder);
                    return ['/card/Roms/gba/a.gba'];
                  },
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      return (paths, explorerCalls);
    }

    testWidgets('uses the system picker when there is one', (tester) async {
      final files = FakeFiles()..picked = ['/cache/x.gba'];
      final (paths, calls) = await pick(tester, files, folder: false);
      expect(paths, ['/cache/x.gba']);
      expect(calls, isEmpty);
    });

    testWidgets('opens the explorer without a system picker', (tester) async {
      final files = FakeFiles()..hasPicker = false;
      final (paths, calls) = await pick(tester, files, folder: true);
      expect(paths, ['/card/Roms/gba/a.gba']);
      expect(calls, [true]);
    });

    testWidgets('falls back to the explorer when the picker fails', (
      tester,
    ) async {
      final files = FakeFiles()
        ..pickError = PlatformException(code: 'ActivityNotFoundException');
      final (paths, calls) = await pick(tester, files, folder: false);
      expect(paths, ['/card/Roms/gba/a.gba']);
      expect(calls, [false]);
    });

    testWidgets('with storage access, opens the explorer, not the picker', (
      tester,
    ) async {
      final files = FakeStorageFiles()
        ..granted = true
        ..picked = ['/cache/x.gba'];
      final (paths, calls) = await pick(tester, files, folder: true);
      expect(paths, ['/card/Roms/gba/a.gba']);
      expect(calls, [true]);
      expect(files.requests, 0);
    });

    testWidgets('asks for access, then opens the explorer', (tester) async {
      final files = FakeStorageFiles()..grantOnRequest = true;
      final (paths, calls) = await pick(tester, files, folder: false);
      expect(find.text('FILE ACCESS'), findsOneWidget);
      await tester.tap(find.text('ALLOW'));
      await tester.pump();
      await tester.pump();
      expect(files.requests, 1);
      expect(calls, [false]);
      expect(paths, ['/card/Roms/gba/a.gba']);
    });

    testWidgets('SYSTEM PICKER keeps the picker and is not asked again', (
      tester,
    ) async {
      final files = FakeStorageFiles()..picked = ['/cache/x.gba'];
      var (paths, calls) = await pick(tester, files, folder: false);
      await tester.tap(find.text('SYSTEM PICKER'));
      await tester.pump();
      await tester.pump();
      expect(files.requests, 0);
      expect(calls, isEmpty);
      expect(paths, ['/cache/x.gba']);
      (paths, calls) = await pick(tester, files, folder: false);
      expect(find.text('FILE ACCESS'), findsNothing);
      expect(paths, ['/cache/x.gba']);
    });

    testWidgets('a refused request falls back to the picker', (tester) async {
      final files = FakeStorageFiles()..picked = ['/cache/x.gba'];
      final (paths, calls) = await pick(tester, files, folder: false);
      await tester.tap(find.text('ALLOW'));
      await tester.pump();
      await tester.pump();
      expect(files.requests, 1);
      expect(calls, isEmpty);
      expect(paths, ['/cache/x.gba']);
    });
  });
}
