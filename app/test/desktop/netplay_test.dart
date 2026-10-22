// Spec: docs/specs/netplay.md
import 'dart:io';

import 'package:dena_emu/src/desktop/netplay.dart';
import 'package:dena_emu/src/session/session_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class FakeNetplay implements NetplayHost {
  NetplayInfo now = const NetplayInfo();
  final calls = <String>[];

  @override
  bool host({required String relay, required bool room, required int delay}) {
    calls.add('host room=$room relay=$relay delay=$delay');
    now = NetplayInfo(
      state: NetplayState.waiting,
      host: true,
      address: '192.168.1.5:47330',
      code: room ? 'K7P2QX' : '',
    );
    return true;
  }

  @override
  bool join(String target, {required String relay, required int delay}) {
    calls.add('join $target relay=$relay delay=$delay');
    now = const NetplayInfo(state: NetplayState.waiting);
    return true;
  }

  @override
  void stop() {
    calls.add('stop');
    now = const NetplayInfo();
  }

  @override
  NetplayInfo get info => now;
}

Widget sheet(NetplayHost net, NetplaySettings settings) => MaterialApp(
  home: Scaffold(
    body: NetplaySheet(
      netplay: net,
      settings: settings,
      poll: const Duration(milliseconds: 50),
    ),
  ),
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_netplay'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('settings default to no relay and AUTO, and are saved', () {
    final file = File('${dir.path}/desktop_netplay.json');
    final s = NetplaySettings.load(file);
    expect((s.relay, s.delay), ('', NetplaySettings.autoDelay));
    expect(netplaySummary(s), 'LAN only');
    s.relay = ' relay.example.net:47340 ';
    s.delay = 9; // clamped to 4
    final again = NetplaySettings.load(file);
    expect((again.relay, again.delay), ('relay.example.net:47340', 4));
    expect(netplaySummary(again), 'relay.example.net:47340');
    file.writeAsStringSync('{broken');
    expect(NetplaySettings.load(file).delay, NetplaySettings.autoDelay);
  });

  test('the join field tells room codes from addresses', () {
    expect(joinKind('K7P2QX'), JoinKind.code);
    expect(joinKind(' k7p2qx '), JoinKind.code);
    expect(joinKind('K7P2Q0'), JoinKind.invalid); // no 0 in codes
    expect(joinKind('K7P2Q'), JoinKind.invalid);
    expect(joinKind('192.168.1.20'), JoinKind.address);
    expect(joinKind('mypc.lan:47330'), JoinKind.address);
    expect(joinKind('[::1]:47330'), JoinKind.address);
    expect(joinKind('hello'), JoinKind.invalid);
    expect(joinKind(''), JoinKind.invalid);
  });

  test('the host info parses, badges and summarizes', () {
    final i = NetplayInfo.parse(
      '{"state":2,"host":false,"slot":1,"method":1,"delay":1,'
      '"rtt_ms":33.6,"via_relay":true,"frame":900,"rollback_frames":12,'
      '"max_rollback":3,"stalls":0,"waiting":false,"desyncs":1,"resyncs":1,'
      '"code":"","address":"","peer":"203.0.113.9","error":""}',
    );
    expect(i.state, NetplayState.playing);
    expect(netplayBadge(i), '[P2]');
    expect(netplaySheetSummary(i), 'Playing as player 2 with 203.0.113.9');
    expect(netplayDetail(i), 'RELAY · 34 ms · rollback, delay 1');
    expect(netplayBadge(NetplayInfo.parse('{"state":0}')), '[OFF]');
    expect(netplayBadge(NetplayInfo.parse('{"state":1}')), '[WAIT]');
    expect(NetplayInfo.parse('nonsense').state, NetplayState.off);
  });

  testWidgets('Host takes focus and hosts on the LAN', (tester) async {
    final net = FakeNetplay();
    await tester.pumpWidget(sheet(net, NetplaySettings(delay: 2)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump(const Duration(milliseconds: 60));
    expect(net.calls, ['host room=false relay= delay=2']);
    expect(find.text('This PC: 192.168.1.5:47330'), findsOneWidget);
    expect(find.text('CANCEL'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no Host room button', (tester) async {
    await tester.pumpWidget(sheet(FakeNetplay(), NetplaySettings()));
    await tester.pump();
    expect(find.text('HOST ROOM'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Join takes a code (through the relay) or an address', (
    tester,
  ) async {
    final net = FakeNetplay();
    final settings = NetplaySettings();
    await tester.pumpWidget(sheet(net, settings));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'k7p2qx');
    await tester.tap(find.text('JOIN'));
    await tester.pump();
    expect(
      find.textContaining(roomNeedsRelay, findRichText: true),
      findsOneWidget,
    );
    settings.relay = 'relay.example.net';
    await tester.tap(find.text('JOIN'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(net.calls, ['join K7P2QX relay=relay.example.net delay=-1']);
    expect(
      find.textContaining('Connecting', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('CANCEL'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(find.byType(EditableText), '192.168.1.20');
    await tester.tap(find.text('JOIN'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      net.calls.last,
      'join 192.168.1.20 relay=relay.example.net delay=-1',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a session that ended shows why', (tester) async {
    final net = FakeNetplay()
      ..now = const NetplayInfo(
        state: NetplayState.ended,
        error: 'The other player runs a different game',
      );
    await tester.pumpWidget(sheet(net, NetplaySettings()));
    await tester.pump();
    expect(find.text('The other player runs a different game'), findsOneWidget);
    expect(find.text('HOST'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the page sets the delay by D-pad and keeps the relay', (
    tester,
  ) async {
    final settings = NetplaySettings();
    await tester.pumpWidget(MaterialApp(home: NetplayPage(settings: settings)));
    await tester.pumpAndSettle();
    expect(find.text('[AUTO]'), findsOneWidget);
    // Focus starts on AUTO; right twice reaches 1.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(settings.delay, 1);
    await tester.enterText(
      find.byType(EditableText),
      'relay.example.net:47340',
    );
    expect(settings.relay, 'relay.example.net:47340');
  });

  testWidgets('the pause sheet offers Netplay only when given its state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget pause(NetplayInfo? n) => MaterialApp(
      home: Scaffold(
        body: PauseSheet(title: 'T', speed: 1, onSpeed: (_) {}, netplay: n),
      ),
    );
    await tester.pumpWidget(pause(null));
    expect(find.text('NETPLAY'), findsNothing);
    await tester.pumpWidget(
      pause(const NetplayInfo(state: NetplayState.playing)),
    );
    expect(find.text('NETPLAY'), findsOneWidget);
    expect(find.text('[P1]'), findsOneWidget);
  });

  test('netplay is offered for the two-player home consoles only', () {
    for (final s in ['nes', 'snes', 'psx', 'n64', 'saturn', 'dreamcast']) {
      expect(systemsWithNetplay, contains(s));
    }
    for (final s in ['gb', 'gbc', 'gba', 'nds', 'psp']) {
      expect(systemsWithNetplay, isNot(contains(s)));
    }
  });
}
