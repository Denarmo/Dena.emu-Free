// The Brutalist component kit. Spec: docs/specs/brutalist-ui.md (3)
import 'dart:io';

import 'package:dena_emu/src/app.dart' show denaTheme;
import 'package:dena_emu/src/ui/app_theme.dart' show contrastRatio;
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget kit(Widget child, {BrutalTokens? tokens}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: denaTheme(tokens ?? BrutalTokens.paper()),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('every token text pair reads at 4.5:1 or better', () {
    for (final t in [
      for (final a in BrutalAccent.values) ...[
        BrutalTokens.paper(accent: a),
        BrutalTokens.ink(accent: a),
      ],
    ]) {
      for (final (fg, bg, what) in [
        (t.ink, t.ground, 'ink/ground'),
        (t.ink, t.panel, 'ink/panel'),
        (t.mutedText, t.panel, 'muted/panel'),
        (t.mutedText, t.ground, 'muted/ground'),
        (t.onFocus, t.focus, 'onFocus/focus'),
        (t.onPrimary, t.primary, 'onPrimary/primary'),
        (t.onHeaderBar, t.headerBar, 'header'),
      ]) {
        expect(
          contrastRatio(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$what dark=${t.dark} ${t.focus}',
        );
      }
    }
  });

  test('no rounded corners anywhere in the kit', () {
    final dir = Directory('lib/src/ui/brutal');
    for (final f in dir.listSync().whereType<File>()) {
      final src = f.readAsStringSync();
      expect(src, isNot(contains('Radius.circular')), reason: f.path);
      expect(src, isNot(contains('StadiumBorder')), reason: f.path);
      expect(src, isNot(contains('RoundedRectangleBorder')), reason: f.path);
    }
  });

  testWidgets('the theme carries the tokens and draws square buttons', (
    tester,
  ) async {
    await tester.pumpWidget(kit(const SizedBox()));
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.extension<BrutalTokens>(), isNotNull);
    final shape = theme.filledButtonTheme.style!.shape!.resolve({});
    expect(shape, isA<BrutalBorder>());
  });

  testWidgets('pressing a button moves it onto its shadow', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      kit(BrutalButton(label: 'Save', onPressed: () => taps++)),
    );
    final t = BrutalTokens.of(tester.element(find.byType(BrutalButton)));
    Offset translation() {
      final tr = tester.widget<Transform>(
        find.descendant(
          of: find.byType(BrutalShadowBox),
          matching: find.byType(Transform),
        ),
      );
      final m = tr.transform;
      return Offset(m.getTranslation().x, m.getTranslation().y);
    }

    expect(translation(), Offset.zero);
    final g = await tester.startGesture(
      tester.getCenter(find.byType(BrutalButton)),
    );
    await tester.pump();
    expect(translation(), t.shadowOffset);
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(translation(), Offset.zero);
    expect(taps, 1);
  });

  testWidgets('HoldToConfirm fires after a full second, not before', (
    tester,
  ) async {
    var fired = 0;
    await tester.pumpWidget(kit(HoldToConfirm(onConfirmed: () => fired++)));
    expect(find.text('HOLD TO DELETE'), findsOneWidget);
    var g = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirm)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await g.up();
    await tester.pump(const Duration(seconds: 2));
    expect(fired, 0);
    g = await tester.startGesture(tester.getCenter(find.byType(HoldToConfirm)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(fired, 0);
    await tester.pump(const Duration(milliseconds: 600));
    expect(fired, 1);
    await g.up();
    await tester.pumpAndSettle();
  });

  test('CheckFilter and BracketSlider text', () {
    expect(
      CheckFilter(label: 'all', checked: true, count: 12, onPressed: null).text,
      '[x]ALL(12)',
    );
    expect(
      const CheckFilter(label: 'nes', checked: false, onPressed: null).text,
      '[ ]NES',
    );
    expect(
      BracketSlider(value: 0.5, onChanged: (_) {}).text,
      '[#####-----] 50%',
    );
    expect(
      BracketSlider(value: 1, onChanged: (_) {}, showPercent: false).text,
      '[##########]',
    );
  });

  testWidgets('BracketSlider steps with the arrow keys', (tester) async {
    var value = 0.5;
    await tester.pumpWidget(
      kit(
        StatefulBuilder(
          builder: (context, set) => BracketSlider(
            value: value,
            autofocus: true,
            onChanged: (v) => set(() => value = v),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, closeTo(0.6, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(value, closeTo(0.4, 1e-9));
    expect(find.text('[####------] 40%'), findsOneWidget);
  });

  testWidgets('CfgToggle and CfgSegment switch', (tester) async {
    var on = false;
    var scale = 1;
    await tester.pumpWidget(
      kit(
        StatefulBuilder(
          builder: (context, set) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CfgToggle(value: on, onChanged: (v) => set(() => on = v)),
              CfgSegment<int>(
                values: const [1, 2, 4],
                selected: scale,
                labelOf: (v) => '${v}X',
                onChanged: (v) => set(() => scale = v),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('OFF'), findsOneWidget);
    await tester.tap(find.byType(CfgToggle));
    await tester.pump(const Duration(milliseconds: 100));
    expect(on, isTrue);
    expect(find.textContaining('ON'), findsWidgets);
    await tester.tap(find.textContaining('4X'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(scale, 4);
  });

  testWidgets('a long CfgRow label or value ellipsizes, never overflows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      kit(
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CfgRow(
              label: 'A label far longer than any phone is wide',
              value: 'and a value that is long as well',
              onOpen: _noop,
            ),
            CfgRow(
              label: 'Another label far longer than the phone',
              control: CfgToggle(value: true, onChanged: null),
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('[ON]'), findsOneWidget);
  });

  testWidgets('the table lights the selected row with a -> marker', (
    tester,
  ) async {
    int? opened;
    await tester.pumpWidget(
      kit(
        SizedBox(
          width: 400,
          height: 300,
          child: BrutalTable(
            columns: const [
              BrutalColumn('Title', sortable: true),
              BrutalColumn('Sys', width: 60),
            ],
            rowCount: 3,
            selectedRow: 1,
            sortColumn: 0,
            onSort: (_) {},
            onRowPressed: (i) => opened = i,
            cellBuilder: (context, row, col, lit) =>
                Text(col == 0 ? 'Game $row' : 'GBA'),
          ),
        ),
      ),
    );
    expect(find.text('TITLE ↓'), findsOneWidget);
    expect(find.text('->'), findsOneWidget);
    await tester.tap(find.text('Game 2'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened, 2);
  });

  testWidgets('every widget renders in Paper and Ink', (tester) async {
    for (final t in [BrutalTokens.paper(), BrutalTokens.ink()]) {
      await tester.pumpWidget(
        kit(
          tokens: t,
          SingleChildScrollView(
            child: Column(
              children: [
                const Sticker('Paused'),
                const LogLine('save state 2', status: LogStatus.ok),
                const KeyValueStrip(entries: [('File', 'a.gba')]),
                const EmptyState(
                  headline: 'No roms found.',
                  message: 'add a folder to start',
                  action: 'Add folder',
                ),
                const PathBar(segments: ['sd', 'roms', 'gba']),
                const SizedBox(width: 300, child: CommandField()),
                const ProgressCell(value: 0.4),
                const BoxThumb(),
                const BrutalHintBar(hints: []),
                BrutalTabBar(
                  tabs: const [
                    BrutalTabItem(label: 'Games'),
                    BrutalTabItem(label: 'Settings'),
                  ],
                  selected: 0,
                  onSelected: (_) {},
                ),
                const SizedBox(
                  width: 300,
                  child: CfgTable(
                    header: 'video.cfg',
                    rows: [CfgRow(label: 'Shader', value: 'LCD')],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('PAUSED'), findsOneWidget);
    }
  });

  testWidgets('dialogs and toasts', (tester) async {
    await tester.pumpWidget(
      kit(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              showBrutalDialog<void>(
                context: context,
                builder: (_) => const BrutalDialog(
                  title: 'Delete?',
                  body: Text('Gone for good.'),
                ),
              );
              ScaffoldMessenger.of(context).showSnackBar(brutalToast('saved'));
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.text('DELETE?'), findsOneWidget);
    expect(find.text('OK > saved'), findsOneWidget);
  });
}

void _noop() {}
