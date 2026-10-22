// Spec: docs/specs/run-ahead.md
import 'dart:io';

import 'package:dena_emu/src/desktop/run_ahead.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_run_ahead'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('defaults to 1 frame preemptive and tells the host at load', () {
    final sent = <(int, int)>[];
    final s = RunAheadSettings.load(
      File('${dir.path}/desktop_run_ahead.json'),
      sink: (mode, frames) => sent.add((mode, frames)),
    );
    expect(s.frames, 1);
    expect(s.method, RunAheadMethod.preemptive);
    expect(sent, [(1, 1)]);
    expect(runAheadSummary(s), '1 frame · Preemptive');
  });

  test('saves, loads and sends every change; off sends mode 0', () {
    final file = File('${dir.path}/desktop_run_ahead.json');
    final sent = <(int, int)>[];
    final s = RunAheadSettings.load(
      file,
      sink: (mode, frames) => sent.add((mode, frames)),
    );
    s.method = RunAheadMethod.runAhead;
    s.frames = 3;
    s.frames = 9; // clamped, no change
    s.frames = 0;
    expect(sent, [(1, 1), (2, 1), (2, 3), (0, 0)]);
    expect(runAheadSummary(s), 'off');
    final again = RunAheadSettings.load(file);
    expect(again.frames, 0);
    expect(again.method, RunAheadMethod.runAhead);
    s.frames = 2;
    expect(
      runAheadSummary(RunAheadSettings.load(file)),
      '2 frames · Run-ahead',
    );
  });

  test('a damaged file gives the defaults', () {
    final file = File('${dir.path}/desktop_run_ahead.json')
      ..writeAsStringSync('{broken');
    final s = RunAheadSettings.load(file);
    expect((s.frames, s.method), (1, RunAheadMethod.preemptive));
    file.writeAsStringSync('{"frames": 7, "method": "nope"}');
    final t = RunAheadSettings.load(file);
    expect((t.frames, t.method), (3, RunAheadMethod.preemptive));
  });

  testWidgets('the page sets frames by D-pad and A, method by tap', (
    tester,
  ) async {
    final settings = RunAheadSettings();
    await tester.pumpWidget(
      MaterialApp(home: RunAheadPage(settings: settings)),
    );
    await tester.pumpAndSettle();
    expect(find.text('[1]'), findsOneWidget);
    // Focus starts on OFF; right twice reaches 2.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(settings.frames, 2);
    await tester.tap(find.text(' OFF '));
    await tester.pumpAndSettle();
    expect(settings.frames, 0);
    await tester.tap(find.text('RUN-AHEAD'));
    await tester.pumpAndSettle();
    expect(settings.method, RunAheadMethod.runAhead);
  });

  testWidgets('the settings row shows the choice and opens the page', (
    tester,
  ) async {
    final settings = RunAheadSettings(frames: 2);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RunAheadTile(settings: settings)),
      ),
    );
    expect(find.text('2 frames · Preemptive >'), findsOneWidget);
    await tester.tap(find.text('RUN-AHEAD'));
    await tester.pumpAndSettle();
    expect(find.byType(RunAheadPage), findsOneWidget);
  });
}
