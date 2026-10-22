import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/skins/skin_store.dart';
import 'package:dena_emu/src/skins/skins_tab.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';
import 'deltaskin_test.dart' show fixtureInfo, zipSkin;

/// Taps [finder] with real async, so the file IO the handler starts runs.
Future<void> tapReal(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
  await tester.pumpAndSettle();
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  testScreens('skins tab after an import', (tester, screen, mode) async {
    final dir = Directory.systemTemp.createTempSync('dena_skins_tab');
    addTearDown(() => dir.deleteSync(recursive: true));
    final skinFile = File(p.join(dir.path, 'test.deltaskin'))
      ..writeAsBytesSync(zipSkin(fixtureInfo()));
    final db = (await tester.runAsync(() => seededDb([])))!;
    final files = FakeFiles()..picked = [skinFile.path];
    final store = SkinStore(p.join(dir.path, 'data'));
    await tester.pumpWidget(
      LibraryScope(
        db: db,
        importer: Importer(db, dir),
        files: files,
        skins: store,
        child: const DenaApp(home: Scaffold(body: SkinsTab())),
      ),
    );
    await settle(tester);
    expect(find.text('Test GBA'), findsNothing);
    await tapReal(tester, find.text('IMPORT SKIN'));
    expect(find.text('Skin imported'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Test GBA'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Test GBA'), findsOneWidget);
    final active = await tester.runAsync(() => store.active('gba'));
    expect(active!.skin.name, 'Test GBA');
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile(goldenName('skins_tab', screen, mode)),
    );

    // Choosing Built-in again deactivates the imported skin.
    final gbaBuiltIn = find.descendant(
      of: find
          .ancestor(of: find.text('Test GBA'), matching: find.byType(CfgTable))
          .first,
      matching: find.byWidgetPredicate(
        (w) => w is CfgToggle && w.semanticLabel == 'Built-in',
      ),
    );
    await tester.ensureVisible(gbaBuiltIn);
    await tester.pumpAndSettle();
    await tapReal(tester, gbaBuiltIn);
    expect(await tester.runAsync(() => store.active('gba')), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });
}
