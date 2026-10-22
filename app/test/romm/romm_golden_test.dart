// Goldens and behaviour of the Brutalist RomM pages.
// Spec: brutalist-ui.md (4.10, 7), romm.md
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/net/http.dart' show streamOver;
import 'package:dena_emu/src/romm/romm_controller.dart';
import 'package:dena_emu/src/romm/romm_settings.dart';
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/screen_matrix.dart';
import 'romm_test.dart' show FakeRomm;

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  await load(brutalMono, [
    for (final w in ['Medium', 'SemiBold', 'Bold'])
      'assets/fonts/ibm_plex_mono/IBMPlexMono-$w.ttf',
  ]);
  await load(brutalDisplay, [
    'assets/fonts/archivo_black/ArchivoBlack-Regular.ttf',
  ]);
  await load('DenaIcons', ['assets/fonts/dena_icons/DenaIcons.otf']);
}

bool _handheld(ScreenSize s) => s == handheld4x3 || s == handheldSquare;

/// A controller signed in to [server] as `me`, from a saved account file.
Future<RommController> _connected(
  WidgetTester tester,
  Directory dir,
  FakeRomm server,
) async {
  final file = File(p.join(dir.path, 'romm', 'account.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    jsonEncode({
      'server': 'http://nas:8080',
      'username': 'me',
      'password': 'pw',
      'auto': true,
      'lastSync': DateTime(2026, 10, 17, 9, 30).toUtc().toIso8601String(),
    }),
  );
  final c = RommController(dataDir: dir, send: streamOver(server.send));
  await tester.runAsync(c.load);
  return c;
}

void main() {
  setUpAll(_loadFonts);
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_romm_ui'));
  tearDown(() => dir.deleteSync(recursive: true));

  testScreens('romm page connected', (tester, screen, mode) async {
    final c = await _connected(tester, dir, FakeRomm());
    await tester.pumpWidget(
      Handheld(
        enabled: _handheld(screen),
        child: DenaApp(home: RommPage(romm: c)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('me'), findsOneWidget);
    expect(find.text('http://nas:8080'), findsOneWidget);
    expect(find.text('[ONLINE]'), findsOneWidget);
    expect(find.textContaining('Synced'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(goldenName('romm_page', screen, mode)),
    );
  });

  testScreens('romm page sign-in form', (tester, screen, mode) async {
    final c = RommController(dataDir: dir, send: streamOver(FakeRomm().send));
    await tester.pumpWidget(
      Handheld(
        enabled: _handheld(screen),
        child: DenaApp(home: RommPage(romm: c)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile(goldenName('romm_form', screen, mode)),
    );
  }, sizes: const [handheld4x3, phone]);

  testWidgets('a wrong password says so in the log line', (tester) async {
    final c = RommController(dataDir: dir, send: streamOver(FakeRomm().send));
    await tester.pumpWidget(DenaApp(home: RommPage(romm: c)));
    await tester.enterText(find.byKey(const Key('romm-server')), 'nas');
    await tester.enterText(find.byKey(const Key('romm-user')), 'me');
    await tester.enterText(find.byKey(const Key('romm-password')), 'nope');
    await tester.tap(find.text('[CONNECT]'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wrong username or password'), findsOneWidget);
    expect(c.connected, isFalse);
  });

  testWidgets('connected: auto-sync toggles, the server opens as a table', (
    tester,
  ) async {
    final c = await _connected(tester, dir, FakeRomm());
    await tester.pumpWidget(DenaApp(home: RommPage(romm: c)));
    await tester.pumpAndSettle();
    expect(c.autoSync, isTrue);
    await tester.tap(find.byKey(const Key('romm-auto')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(c.autoSync, isFalse);

    // Browse holds the focus: A opens the systems table.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(RommPlatformsPage), findsOneWidget);
    expect(find.byType(BrutalTable), findsOneWidget);
    expect(find.text('NES'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('the settings row shows the state and opens the page', (
    tester,
  ) async {
    final c = RommController(dataDir: dir, send: streamOver(FakeRomm().send));
    await tester.pumpWidget(
      DenaApp(
        home: RommScope(
          romm: c,
          child: const Scaffold(body: RommSection()),
        ),
      ),
    );
    expect(find.text('ROMM SERVER'), findsOneWidget);
    expect(find.text('[OFF] >'), findsOneWidget);
    await tester.tap(find.text('ROMM SERVER'));
    await tester.pumpAndSettle();
    expect(find.byType(RommPage), findsOneWidget);
    expect(find.text('[CONNECT]'), findsOneWidget);
  });
}
