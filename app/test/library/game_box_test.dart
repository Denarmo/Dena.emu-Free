// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/game-boxes.md (Acceptance tests)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/box_art.dart';
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/game_box.dart';
import 'package:dena_emu/src/library/game_box_menu.dart';
import 'package:dena_emu/src/library/game_box_model.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/shell/app_shell.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

/// One game per box shape; covers (width / height) for some, so both the
/// art and the placeholder show, and the SNES one is a portrait PAL cover.
const _games = [
  ('snes', 'Shelf Kart', 0.72),
  ('n64', 'Cart Sixty', 1.38),
  ('nes', 'Brick Bros', 0.7),
  ('gb', 'Pocket Quest', 1.0),
  ('gbc', 'Color Run', null),
  ('gba', 'Advance Wars Lite', 1.0),
  ('nds', 'Dual Screens', 0.9),
  ('psx', 'Disc Racer', 1.0),
  ('psp', 'Umd Hero', 0.58),
  ('pico8', 'Tiny Cart', null),
];

/// A flat two-tone PNG of [aspect], standing in for a downloaded cover.
Future<File> _cover(Directory dir, String name, double aspect, int i) async {
  const h = 120.0;
  final w = (h * aspect).roundToDouble();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final hue = (i * 47) % 360;
  c.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()..color = HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.45).toColor(),
  );
  c.drawRect(
    Rect.fromLTWH(0, 0, w, h * 0.22),
    Paint()..color = const Color(0xFFF1C40F),
  );
  c.drawCircle(Offset(w / 2, h * 0.6), h * 0.2, Paint()..color = Colors.white);
  final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final f = File('${dir.path}/$name.png');
  await f.writeAsBytes(png!.buffer.asUint8List());
  return f;
}

Future<LibraryDatabase> _pumpShelf(
  WidgetTester tester, {
  FakeLinks? links,
  bool handheld = false,
  // The grid shows the boxes; the default table shows thumbs.
  LibraryView view = LibraryView.grid,
}) async {
  final dir = Directory.systemTemp.createTempSync('dena_boxes');
  addTearDown(() => dir.deleteSync(recursive: true));
  final db = (await tester.runAsync(() async {
    final db = await seededDb([]);
    for (final (i, (system, title, aspect)) in _games.indexed) {
      final id = await db.addGame(
        system: system,
        title: title,
        fileName: '$title.rom',
        path: '/nowhere/$i',
        sha1: 'box$i',
        size: 1,
        crc32: '0',
        addedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
      );
      if (aspect != null) {
        final f = await _cover(dir, 'c$i', aspect, i);
        await db.setCustomArt(id!, f.path);
      }
    }
    return db;
  }))!;
  final art = BoxArtCache(
    dir.path,
    loadIndex: () async => BoxArtIndex.parse(''),
    fetch: (_) async => null,
  );
  await tester.pumpWidget(
    Handheld(
      enabled: handheld,
      child: LibraryScope(
        db: db,
        importer: Importer(db, dir),
        files: FakeFiles(),
        links: links,
        art: art,
        child: DenaApp(
          theme: ThemeSettings(library: view),
          home: AppShell(onPlay: (_, _) {}),
        ),
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }
  return db;
}

void main() {
  testScreens('box shelf', (tester, screen, mode) async {
    final db = await _pumpShelf(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(GameBox), findsWidgets);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('box_shelf', screen, mode)),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  }, sizes: const [phone, handheld4x3]);

  testScreens('long-press opens the inspection view with its options', (
    tester,
    screen,
    mode,
  ) async {
    final links = FakeLinks();
    // 640x480 and 720x720 are the handheld: a right-hand sheet.
    final db = await _pumpShelf(
      tester,
      links: links,
      handheld: screen != phone,
      view: LibraryView.table,
    );
    await tester.longPress(find.text('ADVANCE_WARS_LITE'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(PlayKey), matching: find.text('PLAY')),
      findsOneWidget,
    );
    for (final label in [
      'RENAME',
      'FAVOURITE',
      'HOME SCREEN',
      'CHOOSE COVER',
      'GAME INFO',
      'HOLD TO DELETE',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // The inspection view and the table row under it.
    expect(find.text('ADVANCE_WARS_LITE'), findsWidgets);
    expect(find.byType(InspectViewport), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('box_menu', screen, mode)),
    );
    await tester.tap(find.text('GAME INFO'));
    await tester.pumpAndSettle();
    expect(find.text('Advance.rom'), findsNothing);
    expect(find.text('Advance Wars Lite.rom'), findsWidgets);
    await tester.tap(find.text('CLOSE'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HOME SCREEN'));
    await tester.pumpAndSettle();
    expect(links.pinned, hasLength(1));
    // The menu closed after pinning.
    expect(find.text('GAME INFO'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  }, sizes: allScreenSizes);

  testWidgets('a short press on delete keeps the game; a 1 s hold deletes '
      'it', (tester) async {
    tester.view.physicalSize = phone.size * phone.pixelRatio;
    tester.view.devicePixelRatio = phone.pixelRatio;
    addTearDown(tester.view.reset);
    final db = await _pumpShelf(tester);
    Future<int> count() async =>
        (await tester.runAsync(() => db.select(db.games).get()))!.length;
    await tester.longPress(find.textContaining('ADVANCE_WARS_LITE'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('HOLD TO DELETE'));
    await tester.pumpAndSettle();
    final hold = tester.getCenter(find.byType(HoldToConfirm));
    var gesture = await tester.startGesture(hold);
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(await count(), _games.length);
    expect(find.text('HOLD TO DELETE'), findsOneWidget);
    gesture = await tester.startGesture(hold);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await gesture.up();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
    }
    expect(await count(), _games.length - 1);
    expect(find.text('HOLD TO DELETE'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });

  test('a GB box is drawn smaller than an N64 box in the same cell', () {
    const stage = Size(150, 150);
    expect(
      boxFootprintOn(boxSpecFor('gb'), stage).width,
      lessThan(boxFootprintOn(boxSpecFor('n64'), stage).width),
    );
  });
}
