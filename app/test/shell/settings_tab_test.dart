// The Brutalist settings tab: CFG sections on grid paper, at every screen
// size and input mode. Spec: docs/specs/brutalist-ui.md (4.6)
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:dena_emu/src/app.dart';

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

void main() {
  testScreens('settings tab', (tester, screen, mode) async {
    final db = await seededDb([]);
    await tester.pumpWidget(shellApp(db));
    await tester.pumpAndSettle();
    // R1 three times: Games, Carts, Apps, Settings.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await tester.pumpAndSettle();
    }
    expect(find.text('APPEARANCE.CFG'), findsOneWidget);
    expect(find.text('[PAPER]'), findsOneWidget);
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile(goldenName('settings_tab', screen, mode)),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await tester.runAsync(db.close);
  });
}
