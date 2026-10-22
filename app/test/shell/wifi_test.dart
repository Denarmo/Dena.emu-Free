import 'package:dena_emu/src/shell/network.dart';
import 'package:dena_emu/src/shell/wifi.dart';
import 'package:dena_emu/src/shell/wifi_page.dart';
import 'package:dena_emu/src/ui/onscreen_keyboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../app_shell_test.dart' show finish, settle;
import '../support/library_fixture.dart';

const _scan =
    'bssid / frequency / signal level / flags / ssid\n'
    'aa:bb:cc:dd:ee:01\t2437\t-70\t[WPA2-PSK-CCMP][ESS]\tHome\n'
    'aa:bb:cc:dd:ee:02\t5180\t-50\t[WPA2-PSK-CCMP][ESS]\tHome\n'
    'aa:bb:cc:dd:ee:03\t2412\t-80\t[ESS]\tCafe\\x20Free\n'
    'aa:bb:cc:dd:ee:04\t2412\t-60\t[WPA2-PSK-CCMP][ESS]\t\n';

/// wpa_supplicant as far as the launcher sees it: records every command.
class FakeWpa {
  final calls = <List<String>>[];
  var networks = <(String, String, String)>[];
  var state = 'DISCONNECTED';

  Future<String> call(List<String> args) async {
    calls.add(args);
    switch (args.first) {
      case 'status':
        return 'wpa_state=$state\n';
      case 'scan_results':
        return _scan;
      case 'list_networks':
        return 'network id / ssid / bssid / flags\n'
            '${networks.map((n) => '${n.$1}\t${n.$2}\tany\t${n.$3}').join('\n')}\n';
      case 'add_network':
        return '${networks.length}\n';
      case 'scan':
        return 'FAIL-BUSY\n';
      default:
        return 'OK\n';
    }
  }
}

void main() {
  test('scan results: strongest per name, names decoded, hidden dropped', () {
    final n = parseScanResults(_scan);
    expect([for (final x in n) x.ssid], ['Home', 'Cafe Free']);
    expect(n.first.signal, -50);
    expect(n.first.bars, 4);
    expect(n.first.secured, isTrue);
    expect(n.last.secured, isFalse);
  });

  test('saved networks, with and without flags', () {
    final s = parseNetworkList(
      'network id / ssid / bssid / flags\n0\tHome\tany\t[CURRENT]\n1\tWork\tany\n',
    );
    expect(
      [for (final x in s) (x.id, x.ssid, x.current)],
      [('0', 'Home', true), ('1', 'Work', false)],
    );
  });

  test('names: escapes and UTF-8', () {
    expect(decodeSsid(r'Caf\xc3\xa9 \"A\"'), 'Café "A"');
    expect(hexSsid('Café'), '436166c3a9');
    expect(validPassword('1234567'), isFalse);
    expect(validPassword('12345678'), isTrue);
    expect(validPassword('x' * 64), isFalse);
  });

  test('joining a new secured network adds, selects and saves it', () async {
    final wpa = FakeWpa()..networks = [('0', 'Work', '[DISABLED]')];
    await WifiControl(run: wpa.call).connect('Home', password: 'secret123');
    expect(wpa.calls.where((c) => c.first != 'list_networks'), [
      ['add_network'],
      ['set_network', '1', 'ssid', '486f6d65'],
      ['set_network', '1', 'psk', '"secret123"'],
      ['select_network', '1'],
      ['enable_network', '0'],
      ['save_config'],
    ]);
  });

  test('a saved network is selected again; open ones need no key', () async {
    final wpa = FakeWpa()..networks = [('0', 'Home', '')];
    await WifiControl(run: wpa.call).connect('Home');
    expect(wpa.calls.where((c) => c.first != 'list_networks'), [
      ['select_network', '0'],
      ['save_config'],
    ]);
    final open = FakeWpa();
    await WifiControl(run: open.call).connect('Cafe Free');
    expect(
      open.calls,
      contains(equals(['set_network', '0', 'key_mgmt', 'NONE'])),
    );
  });

  testWidgets('pick a network, type its password with the D-pad keyboard', (
    tester,
  ) async {
    final wpa = FakeWpa();
    await tester.pumpWidget(
      MaterialApp(
        home: WifiPage(
          wifi: WifiControl(run: wpa.call),
          refreshEvery: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Cafe Free'), findsOneWidget);
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.byType(OnScreenKeyboard), findsOneWidget);
    // Q has focus: A types it, the D-pad moves along the row.
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
    await tester.pump();
    await tester.tap(find.text('E'));
    await tester.pump();
    // Shift is for one letter.
    expect(find.text('r'), findsOneWidget);
    for (final c in 'rtyuio'.split('')) {
      await tester.tap(find.text(c));
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonStart);
    await tester.pumpAndSettle();
    expect(find.byType(OnScreenKeyboard), findsNothing);
    expect(
      wpa.calls,
      contains(equals(['set_network', '0', 'psk', '"qwErtyui"'])),
    );
  });

  testWidgets('Done waits for a valid password', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showOnScreenKeyboard(
              context,
              title: 'Password',
              obscure: true,
              accept: validPassword,
              hint: '8 to 63 characters',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonStart);
    await tester.pumpAndSettle();
    expect(find.text('8 to 63 characters'), findsOneWidget);
    expect(find.text('•••••••'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonStart);
    await tester.pumpAndSettle();
    expect(result, 'qqqqqqqq');
  });

  testWidgets('Settings lists Wi-Fi only with a Wi-Fi control', (tester) async {
    final db = await seededDb([]);
    await tester.pumpWidget(
      NetworkScope(
        online: true,
        wifi: WifiControl(run: FakeWpa().call),
        child: shellApp(db),
      ),
    );
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
      await settle(tester);
    }
    expect(find.text('Wi-Fi'), findsOneWidget);
    await finish(tester, db);
  });
}
