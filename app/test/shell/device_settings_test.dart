// Spec: docs/specs/handheld-ui.md (Device settings)
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/shell/device_settings.dart';
import 'package:dena_emu/src/shell/power_link.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/fake_power.dart';

void main() {
  late Directory card;
  setUp(() => card = Directory.systemTemp.createTempSync('dena_card'));
  tearDown(() => card.deleteSync(recursive: true));

  test('the file lives in Dena/user on the card', () {
    expect(deviceSettingsFile({}), isNull);
    expect(
      deviceSettingsFile({'DENA_CARD': card.path})!.path,
      p.join(card.path, 'Dena', 'user', 'settings.json'),
    );
  });

  test('defaults, damaged files and unknown keys', () async {
    final file = deviceSettingsFile({'DENA_CARD': card.path})!;
    expect((await DeviceSettings.load(file)).brightness, 100);
    await file.parent.create(recursive: true);
    await file.writeAsString('{not json');
    expect((await DeviceSettings.load(file)).brightness, 100);
    await file.writeAsString('{"brightness": 400, "later": "kept"}');
    final s = await DeviceSettings.load(file);
    expect(s.brightness, 100);
    await s.setBrightness(35);
    expect(jsonDecode(await file.readAsString()), {
      'brightness': 35,
      'later': 'kept',
    });
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  testWidgets('the brightness slider works by D-pad and is remembered', (
    tester,
  ) async {
    final file = deviceSettingsFile({'DENA_CARD': card.path})!;
    final settings = (await tester.runAsync(() => DeviceSettings.load(file)))!;
    final ch = FakePowerChannel();
    final link = PowerLink(ch);
    await tester.pumpWidget(
      DenaApp(
        home: Scaffold(
          body: DeviceSection(settings: settings, link: link),
        ),
      ),
    );
    expect(find.text('BRIGHTNESS'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    // The file write runs on the real event loop.
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(ch.sent, ['brightness 95']);
    expect(jsonDecode(file.readAsStringSync()), {'brightness': 95});
    await tester.runAsync(link.close);
  });
}
