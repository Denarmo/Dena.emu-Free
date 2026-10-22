// Spec: docs/specs/handheld-ui.md (USB storage)
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/shell/usb_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_usb'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('only on a handheld with the single-card helper and a UDC', () {
    final helper = p.join(dir.path, 'dena-usb-storage');
    final run = p.join(dir.path, 'run');
    final udc = p.join(dir.path, 'udc');
    UsbStorage? detect({bool handheld = true}) => UsbStorage.detect(
      handheld: handheld,
      helperPath: helper,
      runDir: run,
      udcDir: udc,
    );
    Directory(udc).createSync();
    Directory(p.join(udc, 'musb-hdrc.5.auto')).createSync();
    expect(detect(), isNull);
    File(helper).writeAsStringSync('#!/bin/sh\n');
    expect(detect(handheld: false), isNull);
    expect(detect()!.requestFile.path, p.join(run, 'usb-storage'));
    // No USB device controller: the port can't be a drive.
    Directory(p.join(udc, 'musb-hdrc.5.auto')).deleteSync();
    expect(detect(), isNull);
    Directory(udc).deleteSync();
    expect(detect(), isNull);
  });

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> show(WidgetTester tester, UsbStorage usb) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await tester.pumpWidget(
      Handheld(
        enabled: true,
        child: DenaApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: [
                  ListTile(autofocus: true, title: const Text('Above')),
                  UsbStorageTile(usb: usb),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.gameButtonA);
    expect(find.byType(UsbStoragePage), findsOneWidget);
    expect(find.text('START USB STORAGE'), findsOneWidget);
    expect(find.textContaining('unplug'), findsOneWidget);
  }

  testWidgets('A on Start writes the request, closes and exits 0', (
    tester,
  ) async {
    final request = File(p.join(dir.path, 'run', 'usb-storage'));
    final calls = <String>[];
    final usb = UsbStorage(
      requestFile: request,
      beforeExit: () async => calls.add('close'),
      exitApp: (code) => calls.add('exit $code'),
    );
    await show(tester, usb);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      // Real file I/O: wait for it rather than a fixed delay, which a
      // loaded machine (the full suite in parallel) can outrun.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (calls.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(request.existsSync(), isTrue);
    expect(calls, ['close', 'exit 0']);
  });

  testWidgets('B goes back without a request', (tester) async {
    final request = File(p.join(dir.path, 'run', 'usb-storage'));
    var exited = false;
    final usb = UsbStorage(requestFile: request, exitApp: (_) => exited = true);
    await show(tester, usb);
    await press(tester, LogicalKeyboardKey.gameButtonB);
    expect(find.byType(UsbStoragePage), findsNothing);
    expect(request.existsSync(), isFalse);
    expect(exited, isFalse);
  });

  testWidgets('a request that cannot be written stays on the page', (
    tester,
  ) async {
    // A file where the run directory should be: the request can't be made.
    final blocker = File(p.join(dir.path, 'run'))..writeAsStringSync('');
    var exited = false;
    final usb = UsbStorage(
      requestFile: File(p.join(blocker.path, 'usb-storage')),
      exitApp: (_) => exited = true,
    );
    await show(tester, usb);
    await tester.runAsync(
      () => tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA),
    );
    final error = find.textContaining('Could not start');
    for (var i = 0; i < 500 && error.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(exited, isFalse);
    expect(find.byType(UsbStoragePage), findsOneWidget);
    expect(find.textContaining('Could not start'), findsOneWidget);
  });
}
