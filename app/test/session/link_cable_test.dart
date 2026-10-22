import 'package:dena_emu/src/desktop/netplay.dart';
import 'package:dena_emu/src/session/link_cable.dart';
import 'package:dena_emu/src/session/session_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class FakeLink implements LinkCable {
  LinkState current = LinkState.off;
  bool isHost = true;
  bool scanning = false;
  String lastError = '';
  List<LinkHost> found = [];
  final calls = <String>[];

  @override
  bool host(String name) {
    calls.add('host $name');
    current = LinkState.waiting;
    isHost = true;
    return true;
  }

  @override
  bool join(String address, {int port = 0}) {
    calls.add('join $address:$port');
    current = LinkState.waiting;
    isHost = false;
    return true;
  }

  @override
  void stop() {
    calls.add('stop');
    current = LinkState.off;
  }

  @override
  LinkState get state => current;
  @override
  bool get hosting => isHost;
  @override
  String get error => lastError;
  @override
  String get peer => '192.168.1.7';
  @override
  String get localAddress => '192.168.1.5';
  @override
  bool startScan() => scanning = true;
  @override
  void stopScan() => scanning = false;
  @override
  List<LinkHost> get hosts => found;
}

/// The desktop's link: rooms over the internet (netplay.md).
class FakeRoomsLink extends FakeLink implements LinkRooms {
  String code = '';
  bool relayed = false;

  @override
  bool joinRoom(String target, String relay) {
    calls.add('joinRoom $target $relay');
    current = LinkState.waiting;
    isHost = false;
    return true;
  }

  @override
  String get roomCode => code;
  @override
  bool get viaRelay => relayed;
}

Widget sheet(LinkCable link) => MaterialApp(
  home: Scaffold(
    body: LinkCableSheet(
      link: link,
      gameTitle: 'Pocket Monsters',
      poll: const Duration(milliseconds: 50),
    ),
  ),
);

void main() {
  test('scan results parse into hosts; junk lines are dropped', () {
    expect(
      parseHosts('Game A\t192.168.1.2\t47320\nbad line\nB\t10.0.0.3\tx\n'),
      [(name: 'Game A', address: '192.168.1.2', port: 47320)],
    );
    expect(parseHosts(''), isEmpty);
  });

  testWidgets('hosting shows this device and can be cancelled', (tester) async {
    final link = FakeLink();
    await tester.pumpWidget(sheet(link));
    expect(link.scanning, isTrue);
    expect(
      find.textContaining('Not connected', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('HOST'));
    await tester.pump();
    expect(link.calls, ['host Pocket Monsters']);
    expect(
      find.textContaining('Waiting for another device', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('This device: 192.168.1.5'), findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pump();
    expect(link.calls.last, 'stop');
    expect(find.text('HOST'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(link.scanning, isFalse);
  });

  testWidgets('a found host joins on tap; typed addresses join too', (
    tester,
  ) async {
    final link = FakeLink()
      ..found = [
        (name: 'Pocket Monsters', address: '192.168.1.9', port: 47320),
      ];
    await tester.pumpWidget(sheet(link));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('192.168.1.9'));
    await tester.pump();
    expect(link.calls, ['join 192.168.1.9:47320']);
    expect(
      find.textContaining('Connecting…', findRichText: true),
      findsOneWidget,
    );

    link.current = LinkState.connected;
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      find.textContaining('Connected to 192.168.1.7', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('DISCONNECT'), findsOneWidget);

    link.current = LinkState.off;
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(find.byType(EditableText), ' 10.0.0.4 ');
    await tester.tap(find.text('JOIN'));
    await tester.pump();
    expect(link.calls.last, 'join 10.0.0.4:0');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a dropped link shows why', (tester) async {
    final link = FakeLink()
      ..current = LinkState.failed
      ..lastError = 'the other device disconnected';
    await tester.pumpWidget(sheet(link));
    expect(
      find.textContaining('Disconnected', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('the other device disconnected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the pause sheet offers the link only when given one', (
    tester,
  ) async {
    // Tall enough that the stack folds nothing under SETTINGS.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget pause(LinkCable? link) => MaterialApp(
      home: Scaffold(
        body: PauseSheet(title: 'T', speed: 1, onSpeed: (_) {}, link: link),
      ),
    );
    await tester.pumpWidget(pause(null));
    expect(find.text('LINK CABLE'), findsNothing);
    await tester.pumpWidget(pause(FakeLink()));
    expect(find.text('LINK CABLE'), findsOneWidget);
  });

  testWidgets('phones keep the LAN sheet: no Host room, addresses only', (
    tester,
  ) async {
    await tester.pumpWidget(sheet(FakeRoomsLink()));
    expect(find.text('HOST ROOM'), findsNothing);
    expect(find.text('Join by address'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the desktop adds room codes, no Host room', (tester) async {
    final link = FakeRoomsLink();
    final settings = NetplaySettings();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LinkCableSheet(
            link: link,
            gameTitle: 'Pocket Monsters',
            internet: settings,
            poll: const Duration(milliseconds: 50),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('HOST ROOM'), findsNothing);
    await tester.enterText(find.byType(EditableText), 'k7p2qx');
    await tester.tap(find.text('JOIN'));
    await tester.pump();
    expect(
      find.textContaining(roomNeedsRelay, findRichText: true),
      findsOneWidget,
    );
    settings.relay = 'relay.example.net';

    await tester.enterText(find.byType(EditableText), 'k7p2qx');
    await tester.tap(find.text('JOIN'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(link.calls.last, 'joinRoom K7P2QX relay.example.net');
    link
      ..current = LinkState.connected
      ..relayed = true;
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('RELAY'), findsOneWidget);
    link.current = LinkState.off;
    await tester.pump(const Duration(milliseconds: 60));
    await tester.enterText(find.byType(EditableText), '10.0.0.4:47320');
    await tester.tap(find.text('JOIN'));
    await tester.pump();
    expect(link.calls.last, 'joinRoom 10.0.0.4:47320 ');
    await tester.pumpWidget(const SizedBox());
  });
}
