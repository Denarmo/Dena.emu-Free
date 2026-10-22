// Spec: docs/specs/power-daemon.md (Launcher protocol)

import 'package:dena_emu/src/shell/power_link.dart';
import 'package:dena_emu/src/app.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fake_power.dart';

typedef FakeChannel = FakePowerChannel;

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('save pauses and flushes, then answers saved', () async {
    final ch = FakeChannel();
    final link = PowerLink(ch);
    final steps = <String>[];
    link.onSave = () async {
      steps.add('pause+save');
      await flush();
      steps.add('done');
    };
    ch.incoming.add('save');
    await flush();
    await flush();
    expect(steps, ['pause+save', 'done']);
    expect(ch.sent, ['saved']);
    await link.close();
  });

  test('without a game, save answers at once; failures still answer', () async {
    final ch = FakeChannel();
    final link = PowerLink(ch);
    ch.incoming.add('save');
    await flush();
    expect(ch.sent, ['saved']);
    link.onSave = () async => throw StateError('disk full');
    final errors = <Object>[];
    link.onSaveError = (e, _) => errors.add(e);
    ch.incoming.add('save');
    await flush();
    await flush();
    expect(ch.sent, ['saved', 'saved']);
    expect(errors, [isA<StateError>()]);
    await link.close();
  });

  test(
    'resumed and battery-low reach the UI; unknown lines are ignored',
    () async {
      final ch = FakeChannel();
      final link = PowerLink(ch);
      var resumed = 0, low = 0;
      link.onResumed = () => resumed++;
      link.onBatteryLow = () => low++;
      ch.incoming
        ..add('resumed')
        ..add('battery-low')
        ..add('poweroff')
        ..add('something new');
      await flush();
      expect(resumed, 1);
      expect(low, 1);
      expect(ch.sent, isEmpty);
      await link.close();
    },
  );

  test('activity is throttled; brightness is clamped', () async {
    final ch = FakeChannel();
    var now = DateTime(2026, 10, 16, 12);
    final link = PowerLink(ch, clock: () => now);
    link.activity();
    now = now.add(const Duration(seconds: 3));
    link.activity();
    now = now.add(const Duration(seconds: 8));
    link.activity();
    link
      ..brightness(0)
      ..brightness(140)
      ..brightness(55);
    expect(ch.sent, [
      'activity',
      'activity',
      'brightness 1',
      'brightness 100',
      'brightness 55',
    ]);
    await link.close();
  });

  test('no daemon off Linux', () async {
    expect(await SocketPowerChannel.connect('/nowhere.sock'), isNull);
  });

  testWidgets('the app warns on low battery and reports button presses', (
    tester,
  ) async {
    final ch = FakeChannel();
    final link = PowerLink(ch);
    await tester.pumpWidget(
      PowerScope(
        link: link,
        child: const DenaApp(home: Scaffold(body: Text('home'))),
      ),
    );
    ch.incoming.add('battery-low');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Battery low'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    expect(ch.sent, ['activity']);
    await tester.pumpWidget(const SizedBox());
    expect(link.onBatteryLow, isNull);
    await tester.runAsync(link.close);
  });
}
