// Spec: docs/specs/rewind.md (Long rewind)
import 'dart:io';

import 'package:dena_emu/src/desktop/long_rewind.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Host implements LongRewindHost {
  final scrubs = <int>[];

  @override
  void setBudget(int bytes) {}

  @override
  RewindInfo? begin() => null;

  @override
  void scrub(int position) => scrubs.add(position);

  @override
  void end({required bool keep}) {}
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_rewind'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('defaults to 1 GB; saves and loads the choice', () {
    final file = File('${dir.path}/desktop_rewind.json');
    expect(DesktopRewindSettings.load(file).buffer, RewindBuffer.gb1);
    DesktopRewindSettings.load(file).buffer = RewindBuffer.gb2;
    expect(DesktopRewindSettings.load(file).buffer, RewindBuffer.gb2);
    file.writeAsStringSync('{broken');
    expect(DesktopRewindSettings.load(file).buffer, RewindBuffer.gb1);
    expect(RewindBuffer.short.bytes, 32 << 20);
    expect(RewindBuffer.gb2.bytes, 2048 << 20);
  });

  test('positions are captures, two frames apart', () {
    const info = RewindInfo(count: 9000, position: 9000, fps: 60);
    expect(info.length, const Duration(minutes: 5));
    expect(info.behind(9000), Duration.zero);
    expect(info.behind(8970), const Duration(seconds: 1));
    expect(info.step(9000, -10), 8700);
    expect(info.step(100, -10), 0);
    expect(info.step(8990, 10), 9000);
    final pal = RewindInfo.fromList([500, 7, 1, 2, 50000], position: 7)!;
    expect(pal.behind(0), const Duration(seconds: 20));
    expect(pal.fps, 50);
    expect(RewindInfo.fromList([1, 2], position: 0), isNull);
  });

  test('times and sizes read like the log lines', () {
    expect(formatRewindTime(Duration.zero), '00:00');
    expect(formatRewindTime(const Duration(seconds: 83)), '-01:23');
    expect(
      formatRewindTime(const Duration(seconds: 83), minus: false),
      '01:23',
    );
    expect(formatRewindTime(const Duration(hours: 1, seconds: 3)), '-1:00:03');
    expect(formatRewindBytes(412 << 20), '412 MB');
    expect(formatRewindBytes(1024 << 20), '1.0 GB');
  });

  Future<(_Host, List<bool?>)> pumpSheet(WidgetTester tester) async {
    final host = _Host();
    final popped = <bool?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async => popped.add(
                await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      body: RewindScrubSheet(
                        info: const RewindInfo(
                          count: 3600,
                          position: 3600,
                          bytes: 300 << 20,
                          budget: 1024 << 20,
                        ),
                        host: host,
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (host, popped);
  }

  testWidgets('arrows, page keys and buttons scrub; resume pops true', (
    tester,
  ) async {
    final (host, popped) = await pumpSheet(tester);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.text('> rewind: 02:00 in 300 MB of 1.0 GB'), findsOneWidget);
    // The bar has focus: Left is one of 20 cells (6 s of 120 s).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(host.scrubs.last, 3420);
    expect(find.text('-00:06'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump();
    expect(host.scrubs.last, 3120);
    await tester.tap(find.text('+1S'));
    await tester.pump();
    expect(host.scrubs.last, 3150);
    expect(find.text('-00:15'), findsOneWidget);
    // Past the newest clamps and sends nothing more.
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('+10S'));
      await tester.pump();
    }
    expect(host.scrubs.last, 3600);
    final n = host.scrubs.length;
    await tester.tap(find.text('+10S'));
    await tester.pump();
    expect(host.scrubs.length, n);
    await tester.tap(find.text('RESUME HERE'));
    await tester.pumpAndSettle();
    expect(popped, [true]);
  });

  testWidgets('back to now pops false', (tester) async {
    final (_, popped) = await pumpSheet(tester);
    await tester.tap(find.text('BACK TO NOW'));
    await tester.pumpAndSettle();
    expect(popped, [false]);
  });
}
