// Spec: docs/specs/handheld-ui.md (Acceptance tests)
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:dena_emu/src/session/session_screen.dart';
import 'package:dena_emu/src/session/state_slots.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/library_fixture.dart';
import '../support/screen_matrix.dart';

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('B closes a sheet, then a page, and does nothing at the root', (
    tester,
  ) async {
    await tester.pumpWidget(
      DenaApp(
        home: Builder(
          builder: (context) => TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (page) => Scaffold(
                  body: TextButton(
                    autofocus: true,
                    onPressed: () => showModalBottomSheet<void>(
                      context: page,
                      builder: (_) => const Text('sheet'),
                    ),
                    child: const Text('open sheet'),
                  ),
                ),
              ),
            ),
            child: const Text('open page'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(find.text('open sheet'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('open page'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('open page'), findsOneWidget);
  });

  testScreens(
    'handheld library with hint bar',
    (tester, screen, mode) async {
      final db = await seededDb(['Alpha Quest', 'Beta Racer']);
      await tester.pumpWidget(Handheld(enabled: true, child: shellApp(db)));
      await settle(tester);
      expect(find.byType(HintBar), findsOneWidget);
      expect(find.text('DETAILS'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(goldenName('handheld_games', screen, mode)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
      expect(find.text('DETAILS'), findsOneWidget, reason: 'Carts tab');
      // No Apps tab on handhelds: R1 goes on to Settings.
      expect(find.text('Apps'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
      expect(find.text('OPEN'), findsOneWidget, reason: 'Settings tab');
      // Touch-only and Android-only entries are hidden.
      expect(find.text('Skins'), findsNothing);
      expect(find.text('Audio latency'), findsNothing);
      expect(find.text('Latency test'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
      expect(find.text('DETAILS'), findsOneWidget, reason: 'wraps to Games');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      await tester.runAsync(db.close);
    },
    sizes: const [handheld4x3, handheldSquare],
    modes: const [InputMode.focus],
  );

  testScreens(
    'handheld pause sheet',
    (tester, screen, mode) async {
      await tester.pumpWidget(
        Handheld(
          enabled: true,
          child: DenaApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: PauseSheet(
                  title: 'Alpha Quest',
                  speed: 1,
                  onSpeed: (_) {},
                  onCapture: () {},
                  states: true,
                  slots: [
                    for (final id in ['quick', 'slot1', 'slot2', 'slot3'])
                      StateSlot(
                        id: id,
                        label: id,
                        statePath: '/none/$id.state',
                        pngPath: '/none/$id.png',
                      ),
                  ],
                  meta: const [
                    ('FILE', 'ALPHA_QUEST.GBA'),
                    ('SESSION', '00:14:20'),
                    ('CORE', 'mgba // 1X'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('RESUME'), findsWidgets);
      expect(find.byType(BrutalHintBar), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(goldenName('handheld_pause', screen, mode)),
      );
    },
    sizes: const [handheld4x3, handheldSquare],
    modes: const [InputMode.focus],
  );

  test('handheld mode needs Linux and DENA_HANDHELD=1', () {
    // This suite runs on Windows/macOS/Linux desktops without the variable.
    expect(detectHandheld(), isFalse);
    expect(LibraryScope, isNotNull);
  });
}
