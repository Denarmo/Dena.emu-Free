// The whole handheld flow by buttons only, at 640×480 (CLAUDE.md §5).
// Spec: docs/specs/handheld-ui.md (Buttons, Device settings)
import 'dart:io';

import 'package:dena_emu/src/library/games_tab.dart';
import 'package:dena_emu/src/library/game_box_menu.dart';
import 'package:dena_emu/src/shell/device_settings.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:dena_emu/src/ui/onscreen_keyboard.dart';
import 'package:dena_emu/src/shell/power_link.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../session_screen_test.dart'
    show FakeGameApi, closeDb, firstGame, sessionApp;
import '../support/fake_power.dart';
import '../support/library_fixture.dart';

const _games = 30;

Future<void> settle(WidgetTester tester) async {
  // Drift streams resolve asynchronously; let them deliver, then settle.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await settle(tester);
}

/// Holds [key] like the launcher does: down, [repeats] repeats, up.
Future<void> hold(
  WidgetTester tester,
  LogicalKeyboardKey key,
  int repeats,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.pump();
  for (var i = 0; i < repeats; i++) {
    await tester.sendKeyRepeatEvent(key);
    await tester.pump(const Duration(milliseconds: 80));
  }
  await tester.sendKeyUpEvent(key);
  await settle(tester);
}

BuildContext? get _focused => FocusManager.instance.primaryFocus?.context;

/// The texts inside the focused widget, e.g. a card's title and system.
List<String> focusedTexts() {
  final texts = <String>[];
  void visit(Element e) {
    if (e.widget case Text(:final data?)) texts.add(data);
    e.visitChildren(visit);
  }

  (_focused as Element?)?.visitChildren(visit);
  return texts;
}

bool focusIn<T extends Widget>() =>
    _focused?.findAncestorWidgetOfExactType<T>() != null;

/// The focused widget's rectangle on screen.
Rect focusedRect() {
  final box = _focused!.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Whether the table row showing [title] is lit: its marker cell reads
/// `->` (brutalist-ui.md 4.2).
bool hasRing(WidgetTester tester, String title) {
  final row = find.ancestor(
    of: find.text(title),
    matching: find.byType(BrutalPressable),
  );
  return find
      .descendant(of: row.first, matching: find.text('->'))
      .evaluate()
      .isNotEmpty;
}

/// Whether focus is in a row of the library table.
bool focusInTable() =>
    focusIn<BrutalTable>() && focusedTexts().any((t) => t.startsWith('GAME_'));

void main() {
  late Directory card;
  late FakePowerChannel channel;
  late PowerLink link;
  // Every button also tells the daemon about activity; keep brightness.
  List<String> brightness() =>
      channel.sent.where((l) => l.startsWith('brightness')).toList();
  late ThemeSettings theme;

  setUp(() {
    card = Directory.systemTemp.createTempSync('dena_nav');
    channel = FakePowerChannel();
    link = PowerLink(channel);
    theme = ThemeSettings();
    played = [];
  });
  tearDown(() => card.deleteSync(recursive: true));

  /// The app as the SD-card launcher starts it, with a library of [_games].
  Future<Future<void> Function()> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // No touch on a handheld: the focus ring is always on.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final db = (await tester.runAsync(
      () => seededDb([for (var i = 0; i < _games; i++) 'Game $i']),
    ))!;
    final file = deviceSettingsFile({'DENA_CARD': card.path})!;
    final device = (await tester.runAsync(() => DeviceSettings.load(file)))!;
    await tester.pumpWidget(
      Handheld(
        enabled: true,
        child: PowerScope(
          link: link,
          device: device,
          child: shellApp(db, theme: theme),
        ),
      ),
    );
    await settle(tester);
    return () async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      await tester.runAsync(db.close);
      await tester.runAsync(link.close);
    };
  }

  testWidgets('the first game has focus and a ring at start; held arrows '
      'scroll the grid', (tester) async {
    final finish = await start(tester);
    expect(focusedTexts(), contains('GAME_0'));
    expect(hasRing(tester, 'GAME_0'), isTrue);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedTexts(), contains('GAME_1'));
    expect(hasRing(tester, 'GAME_0'), isFalse);

    // Held down: the launcher repeats every 80 ms; each repeat moves a row.
    final scroll = tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(BrutalTable),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    await hold(tester, LogicalKeyboardKey.arrowDown, 16);
    expect(focusInTable(), isTrue);
    expect(focusedTexts(), isNot(contains('GAME_1')));
    expect(scroll.pixels, greaterThan(0));
    // The focused row is scrolled into view, above the hint bar.
    final rect = focusedRect();
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(480 - HintBar.height));

    // Back to the top, along the tool row into the search field and out
    // again: the field does not keep the D-pad.
    await hold(tester, LogicalKeyboardKey.arrowUp, 30);
    for (var i = 0; i < 3 && !focusIn<CommandField>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowLeft);
    }
    expect(focusIn<CommandField>(), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<CommandField>(), isFalse);
    // Down past the filters and the header lands on a row again.
    for (var i = 0; i < 6 && !focusInTable(); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusInTable(), isTrue);
    await finish();
  });

  testWidgets('A plays, Y opens details with focus, B closes sheet and '
      'dialogs', (tester) async {
    final finish = await start(tester);
    await press(tester, LogicalKeyboardKey.gameButtonY);
    expect(find.byType(PlayKey), findsOneWidget);
    expect(focusedTexts(), contains('PLAY'));

    // Rename opens the on-screen keyboard; B cancels.
    for (var i = 0; i < 6 && !focusedTexts().contains('RENAME'); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedTexts(), contains('RENAME'));
    await press(tester, LogicalKeyboardKey.gameButtonA);
    expect(find.byType(OnScreenKeyboard), findsOneWidget);
    await press(tester, LogicalKeyboardKey.gameButtonB);
    expect(find.byType(OnScreenKeyboard), findsNothing);
    // Cancelling the rename closes the inspection view too.
    expect(find.byType(PlayKey), findsNothing);
    expect(focusedTexts(), contains('GAME_0'));

    // Delete needs a 1 s hold: a short A press keeps the game, B closes.
    await press(tester, LogicalKeyboardKey.gameButtonY);
    for (var i = 0; i < 12 && !focusedTexts().contains('HOLD TO DELETE'); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedTexts(), contains('HOLD TO DELETE'));
    await press(tester, LogicalKeyboardKey.gameButtonA);
    expect(find.byType(PlayKey), findsOneWidget);
    await press(tester, LogicalKeyboardKey.gameButtonB);
    expect(find.byType(PlayKey), findsNothing);
    expect(find.text('GAME_0'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.gameButtonA);
    expect(played.single.title, 'Game 0');
    await finish();
  });

  testWidgets('L1 / R1 cycle every tab and focus lands in each', (
    tester,
  ) async {
    final finish = await start(tester);
    // Something to step to; the arrows never end up nowhere after a switch.
    Future<void> moves() async {
      final before = _focused;
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused, isNot(before), reason: 'arrows work in the new tab');
      await press(tester, LogicalKeyboardKey.arrowUp);
    }

    await press(tester, LogicalKeyboardKey.gameButtonRight1);
    expect(focusedTexts(), contains('[LAUNCH EXPLORE]'));
    await moves();
    // Handhelds have no Apps tab: Carts is followed by Settings.
    await press(tester, LogicalKeyboardKey.gameButtonRight1);
    expect(
      focusIn<BracketSlider>(),
      isTrue,
      reason: 'Settings starts on Device',
    );
    await moves();
    await press(tester, LogicalKeyboardKey.gameButtonRight1);
    expect(focusedTexts(), contains('GAME_0'));
    await press(tester, LogicalKeyboardKey.gameButtonLeft1);
    expect(focusIn<BracketSlider>(), isTrue);
    await press(tester, LogicalKeyboardKey.gameButtonLeft1);
    expect(focusedTexts(), contains('[LAUNCH EXPLORE]'));
    await finish();
  });

  testWidgets('Settings: brightness and theme by D-pad and A', (tester) async {
    final finish = await start(tester);
    await press(tester, LogicalKeyboardKey.gameButtonLeft1);
    expect(focusIn<BracketSlider>(), isTrue);
    // The file write runs on the real event loop.
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle(tester);
    expect(brightness(), ['brightness 95']);
    // Down leaves the slider without changing it.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<BracketSlider>(), isFalse);
    expect(brightness(), ['brightness 95']);
    // The theme mode sits inline under the device rows.
    for (var i = 0; i < 4 && !focusIn<CfgSegment<ThemeMode>>(); i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusIn<CfgSegment<ThemeMode>>(), isTrue);
    bool lit(String label) => focusedTexts().any((t) => t.contains(label));
    // Focus may land on any segment; walk right, then left, to the one.
    Future<void> seek(WidgetTester tester, bool Function() found) async {
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        for (var i = 0; i < 3 && !found(); i++) {
          await press(tester, key);
        }
      }
    }

    await seek(tester, () => lit('INK'));
    expect(theme.mode, ThemeMode.light);
    await press(tester, LogicalKeyboardKey.gameButtonA);
    expect(theme.mode, ThemeMode.dark);
    // Down reaches the accents.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusIn<CfgSegment<BrutalAccent>>(), isTrue);
    await seek(tester, () => lit('GOLD'));
    await press(tester, LogicalKeyboardKey.gameButtonA);
    expect(theme.accent, BrutalAccent.gold);
    await finish();
  });

  testWidgets('Menu and Start do nothing on the library; Select sorts, X '
      'shuffles', (tester) async {
    final finish = await start(tester);
    for (final key in [
      LogicalKeyboardKey.gameButtonMode,
      LogicalKeyboardKey.gameButtonStart,
      LogicalKeyboardKey.gameButtonLeft2,
      LogicalKeyboardKey.gameButtonRight2,
    ]) {
      await press(tester, key);
      expect(tester.takeException(), isNull);
      expect(find.byType(GamesTab), findsOneWidget);
      expect(focusedTexts(), contains('GAME_0'));
    }
    // Select steps the sort key; the footer says which.
    expect(find.text('$_games ROWS // SORT=TITLE ASC'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.gameButtonSelect);
    expect(find.text('$_games ROWS // SORT=SYS ASC'), findsOneWidget);
    // X focuses a random other game and scrolls it into view.
    for (var i = 0; i < 5; i++) {
      final before = focusedTexts();
      await press(tester, LogicalKeyboardKey.gameButtonX);
      expect(focusInTable(), isTrue);
      expect(focusedTexts(), isNot(before));
      final rect = focusedRect();
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(480 - HintBar.height));
    }
    await finish();
  });

  testWidgets('the pause sheet takes focus; B resumes', (tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = (await tester.runAsync(() => seededDb(['Pocket Quest'])))!;
    final game = await firstGame(tester, db);
    final api = FakeGameApi();
    late void Function() menu;
    await tester.pumpWidget(
      Handheld(
        enabled: true,
        child: sessionApp(
          db,
          game,
          api,
          registerEvents: (e) {
            if (e != null) menu = e.onMenuRequested;
          },
        ),
      ),
    );
    await tester.tap(find.text('library'));
    await tester.pumpAndSettle();
    // The Menu button reaches the app as a call from the embedder.
    menu();
    await tester.pumpAndSettle();
    expect(api.calls.last, 'pause');
    expect(find.byType(BrutalHintBar), findsOneWidget);
    expect(focusedTexts(), contains('RESUME'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedTexts(), isNot(contains('RESUME')));
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(api.calls.last, 'resume');
    expect(find.text('RESUME'), findsNothing);
    await closeDb(tester, db);
  });
}
