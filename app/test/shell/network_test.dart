import 'dart:io';

import 'package:dena_emu/src/shell/network.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../app_shell_test.dart' show finish, settle;
import '../support/library_fixture.dart';

void main() {
  group('detectWifiHardware', () {
    late Directory sys;
    setUp(() => sys = Directory.systemTemp.createTempSync('sys'));
    tearDown(() => sys.deleteSync(recursive: true));

    test('no sysfs classes: no Wi-Fi', () {
      expect(detectWifiHardware(sys: sys.path), isFalse);
    });

    test('only wired and loopback interfaces: no Wi-Fi', () {
      Directory('${sys.path}/class/net/lo').createSync(recursive: true);
      Directory('${sys.path}/class/net/eth0').createSync(recursive: true);
      Directory('${sys.path}/class/ieee80211').createSync(recursive: true);
      expect(detectWifiHardware(sys: sys.path), isFalse);
    });

    test('an interface with a wireless directory', () {
      Directory('${sys.path}/class/net/wlan0/wireless')
          .createSync(recursive: true);
      expect(detectWifiHardware(sys: sys.path), isTrue);
    });

    test('a wireless PHY before its interface is up', () {
      Directory('${sys.path}/class/ieee80211/phy0').createSync(recursive: true);
      expect(detectWifiHardware(sys: sys.path), isTrue);
    });

    test('phones are always online', () {
      expect(detectNetwork(handheld: false, sys: sys.path), isTrue);
      expect(detectNetwork(handheld: true, sys: sys.path), isFalse);
    });
  });

  Future<void> openTab(WidgetTester tester, int r1Presses) async {
    for (var i = 0; i < r1Presses; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
    }
  }

  Widget app(Widget shell, {required bool online}) =>
      NetworkScope(online: online, child: shell);

  testWidgets('no Wi-Fi: online features are out of Settings and Carts', (
    tester,
  ) async {
    // Tall enough that the whole Settings list is built at once.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await seededDb([]);
    await tester.pumpWidget(app(shellApp(db), online: false));
    await settle(tester);
    await openTab(tester, 1);
    expect(find.text('[LAUNCH EXPLORE]'), findsNothing);
    expect(find.text('DENA_EXPLORE'), findsNothing);
    expect(find.text('[BROWSE BBS]'), findsNothing);
    // The carts themselves stay, with adding from files.
    expect(find.text('[ADD CARTS]'), findsOneWidget);
    await openTab(tester, 2);
    expect(find.text('LATENCY TEST'), findsOneWidget);
    expect(find.text('APPEARANCE.CFG'), findsOneWidget);
    for (final gone in [
      'DRIVE.CFG',
      'WEB FILES',
      'Your server',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    await finish(tester, db);
  });
}
