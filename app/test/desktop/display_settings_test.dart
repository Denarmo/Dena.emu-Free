// Spec: docs/specs/controller-mode.md (Settings)
import 'dart:io';

import 'package:dena_emu/src/desktop/display_settings.dart';
import 'package:dena_emu/src/desktop/launch_rule.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_display'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('defaults to Auto; saves and loads the choice', () {
    final file = File('${dir.path}/desktop_display.json');
    expect(
      DesktopDisplaySettings.load(file).fullscreenAtLaunch,
      FullscreenAtLaunch.auto,
    );
    DesktopDisplaySettings.load(file).fullscreenAtLaunch =
        FullscreenAtLaunch.never;
    expect(
      DesktopDisplaySettings.load(file).fullscreenAtLaunch,
      FullscreenAtLaunch.never,
    );
    file.writeAsStringSync('{broken');
    expect(
      DesktopDisplaySettings.load(file).fullscreenAtLaunch,
      FullscreenAtLaunch.auto,
    );
  });

  testWidgets('the page picks a choice by D-pad and A', (tester) async {
    final settings = DesktopDisplaySettings();
    await tester.pumpWidget(
      MaterialApp(home: FullscreenAtLaunchPage(settings: settings)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Always start fullscreen'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(settings.fullscreenAtLaunch, FullscreenAtLaunch.never);
  });
}
