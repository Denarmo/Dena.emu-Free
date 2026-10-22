import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/game_media.dart';
import 'package:dena_emu/src/library/launch_animation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'media_art_test.dart' show game;

/// Counts how often the page under the launch starts.
class _Page extends StatefulWidget {
  const _Page(this.started);

  final List<int> started;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  void initState() {
    super.initState();
    widget.started.add(1);
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Colors.black,
    child: Center(child: Text('game')),
  );
}

void main() {
  late List<int> started;
  late NavigatorState nav;

  Future<void> launch(
    WidgetTester tester,
    Game g, {
    bool reduceMotion = false,
  }) async {
    started = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            nav = Navigator.of(context);
            return const Scaffold(body: Text('library'));
          },
        ),
      ),
    );
    nav.push(
      LaunchRoute<void>(
        builder: (_) => _Page(started),
        game: g,
        reduceMotion: reduceMotion,
        origin: const Rect.fromLTWH(10, 10, 80, 110),
      ),
    );
    await tester.pump();
  }

  testWidgets('the game starts loading on the first frame', (tester) async {
    await launch(tester, game());
    expect(started, [1]);
    // The library still shows while the box flies in.
    expect(find.text('library'), findsOneWidget);
    await tester.pump(LaunchRoute.defaultDuration ~/ 2);
    expect(find.byType(GameMedia), findsOneWidget);
    // A hard cut: the overlay is gone the frame the launch ends.
    await tester.pumpAndSettle();
    expect(find.byType(GameMedia), findsNothing);
    expect(find.text('game'), findsOneWidget);
    expect(started, [1]);
  });

  testWidgets('a tap skips to the game', (tester) async {
    await launch(tester, game());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump();
    expect(find.byType(GameMedia), findsNothing);
    expect(find.text('game'), findsOneWidget);
    // Taps reach the game afterwards.
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('a button skips to the game', (tester) async {
    await launch(tester, game(system: 'psx'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(find.byType(GameMedia), findsNothing);
  });

  testWidgets('reduced motion is one still frame, then a cut', (
    tester,
  ) async {
    final g = game();
    await launch(tester, g, reduceMotion: true);
    expect(started, [1]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GameMedia), findsOneWidget);
    expect(find.textContaining(bootLine(g), findRichText: true), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 280));
    expect(find.byType(GameMedia), findsNothing);
    expect(find.text('game'), findsOneWidget);
  });

  test('the launch is 560 ms of hard steps', () {
    expect(LaunchRoute.defaultDuration, const Duration(milliseconds: 560));
    expect(LaunchRoute.handheldDuration, LaunchRoute.defaultDuration);
    LaunchStep at(int ms) => launchStepAt(Duration(milliseconds: ms));
    expect(at(0).inverted, isTrue);
    expect(at(79).centred, isFalse);
    expect(at(80).centred, isTrue);
    expect(at(80).inverted, isFalse);
    // The lid: closed, 45 degrees, open.
    expect([at(160).lid, at(240).lid, at(320).lid], [0, 1, 2]);
    // The media rises in two steps.
    expect([at(200).media, at(280).media, at(360).media], [0, 1, 2]);
    expect(at(399).log, isFalse);
    expect(at(400).log, isTrue);
    // Nothing moves between step edges, which fall on a 40 ms grid; the
    // longest hold (closed box, boot line) is two 80 ms steps.
    final edges = <int>[];
    LaunchStep? last;
    for (var ms = 0; ms <= 560; ms++) {
      final s = at(ms);
      if (s != last) edges.add(ms);
      last = s;
    }
    expect(edges, everyElement(predicate<int>((ms) => ms % 40 == 0)));
    for (var i = 1; i < edges.length; i++) {
      expect(edges[i] - edges[i - 1], inInclusiveRange(40, 160));
    }
  });

  testWidgets('the boot line prints under the box at 400 ms', (tester) async {
    final g = game();
    await launch(tester, g);
    await tester.pump(const Duration(milliseconds: 380));
    expect(find.textContaining(bootLine(g), findRichText: true), findsNothing);
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.textContaining(bootLine(g), findRichText: true), findsOneWidget);
    expect(find.textContaining('... ok', findRichText: true), findsOneWidget);
  });

  for (final system in [
    'nes',
    'snes',
    'n64',
    'gba',
    'nds',
    'psx',
    'psp',
    'pico8',
  ]) {
    testWidgets('every frame draws for $system', (tester) async {
      await launch(tester, game(system: system));
      for (var i = 0; i < 20; i++) {
        await tester.pump(LaunchRoute.defaultDuration ~/ 20);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
    });
  }

  testWidgets('LaunchOrigin reports where the box is', (tester) async {
    final g = game();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned(
              left: 30,
              top: 40,
              width: 100,
              height: 140,
              child: LaunchOrigin(game: g, child: const SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
    expect(LaunchOrigin.rectOf(g), const Rect.fromLTWH(30, 40, 100, 140));
    expect(LaunchOrigin.rectOf(game(sha1: 'other')), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(LaunchOrigin.rectOf(g), isNull);
  });

  testWidgets('media draws with and without art', (tester) async {
    for (final system in ['gb', 'gbc', 'genesis', '3ds', 'psx', 'psp']) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(width: 200, child: GameMedia(system: system)),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });
}
