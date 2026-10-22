// Goldens of the handheld system pages in the Brutalist look: file explorer,
// game folders, Wi-Fi, USB storage, on-screen keyboard and the web file
// manager address. Spec: docs/specs/brutalist-ui.md (4.9, 7)
import 'dart:io';

import 'package:dena_emu/src/app.dart' show denaTheme;
import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/library/file_explorer.dart';
import 'package:dena_emu/src/library/game_folders.dart';
import 'package:dena_emu/src/library/game_folders_page.dart';
import 'package:dena_emu/src/library/importer.dart';
import 'package:dena_emu/src/library/library_scope.dart' show importExtensions;
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/shell/usb_storage.dart';
import 'package:dena_emu/src/shell/wifi.dart';
import 'package:dena_emu/src/shell/wifi_page.dart';
import 'package:dena_emu/src/ui/brutal/brutal.dart';
import 'package:dena_emu/src/ui/dena_icons.dart';
import 'package:dena_emu/src/ui/onscreen_keyboard.dart';
import 'package:dena_emu/src/webfiles/web_files_page.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../support/screen_matrix.dart';

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

/// Lets real I/O finish, then rebuilds.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _show(WidgetTester tester, ScreenSize screen, Widget page) async {
  await tester.pumpWidget(
    Handheld(
      enabled: screen != phone,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: denaTheme(BrutalTokens.paper()),
        home: page,
      ),
    ),
  );
  await _settle(tester);
}

const _scan =
    'bssid / frequency / signal level / flags / ssid\n'
    'aa:bb:cc:dd:ee:01\t2437\t-50\t[WPA2-PSK-CCMP][ESS]\tHome\n'
    'aa:bb:cc:dd:ee:02\t2412\t-80\t[ESS]\tCafe\\x20Free\n'
    'aa:bb:cc:dd:ee:03\t5180\t-65\t[WPA2-PSK-CCMP][ESS]\tNeighbour 5G\n';

Future<String> _wpa(List<String> args) async => switch (args.first) {
  'status' => 'wpa_state=COMPLETED\nssid=Home\nip_address=192.168.1.20\n',
  'scan_results' => _scan,
  'list_networks' =>
    'network id / ssid / bssid / flags\n0\tHome\tany\t[CURRENT]\n'
        '1\tWork\tany\t\n',
  _ => 'OK\n',
};

void main() {
  setUpAll(_loadFonts);

  // A fixed path so the path bar reads the same on every run.
  final card = Directory(p.join(Directory.systemTemp.path, 'dena_card'));
  setUpAll(() {
    if (card.existsSync()) card.deleteSync(recursive: true);
    final day = DateTime(2026, 10, 18, 12);
    for (final d in ['gba', 'gbc', 'nes']) {
      Directory(p.join(card.path, 'Roms', d)).createSync(recursive: true);
    }
    for (final (name, bytes) in [
      ('Alpha Quest (USA).gba', 4 << 20),
      ('Beta Racer.gb', 256 << 10),
      ('Gamma Puzzle.nes', 40 << 10),
    ]) {
      File(p.join(card.path, 'Roms', name))
        ..writeAsBytesSync(List.filled(bytes, 0))
        ..setLastModifiedSync(day);
    }
  });
  tearDownAll(() => card.deleteSync(recursive: true));

  testScreens('file explorer', (tester, screen, mode) async {
    await _show(
      tester,
      screen,
      FileExplorerPage(
        roots: [
          ExplorerRoot(
            'SD card',
            card.path,
            DenaIcons.folder,
            start: p.join(card.path, 'Roms'),
          ),
        ],
        folderMode: false,
        extensions: importExtensions,
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('handheld_explorer', screen, mode)),
    );
  });

  testScreens('game folders', (tester, screen, mode) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = LibraryDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final folders = GameFolders(
      file: File(p.join(card.path, 'data', 'folders.json')),
      db: db,
      importer: Importer(db, Directory(p.join(card.path, 'data', 'games'))),
      fixed: [p.join(card.path, 'Roms')],
    );
    await _show(tester, screen, GameFoldersPage(folders: folders));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('handheld_game_folders', screen, mode)),
    );
  });

  testScreens('wi-fi', (tester, screen, mode) async {
    await _show(
      tester,
      screen,
      WifiPage(
        wifi: WifiControl(run: _wpa),
        refreshEvery: const Duration(hours: 1),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('handheld_wifi', screen, mode)),
    );
  });

  testScreens('usb storage', (tester, screen, mode) async {
    await _show(
      tester,
      screen,
      UsbStoragePage(
        usb: UsbStorage(
          requestFile: File(p.join(card.path, 'run', 'usb-storage')),
          exitApp: (_) {},
        ),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('handheld_usb_storage', screen, mode)),
    );
  });

  testScreens('on-screen keyboard', (tester, screen, mode) async {
    await _show(
      tester,
      screen,
      const OnScreenKeyboard(title: 'Wi-Fi password', initial: 'Dena'),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('handheld_keyboard', screen, mode)),
    );
  });

  testScreens('web file manager address', (tester, screen, mode) async {
    await _show(
      tester,
      screen,
      Scaffold(
        body: BrutalGridPaper(
          child: ListView(
            padding: const EdgeInsets.all(BrutalTokens.s2),
            children: const [
              WebFilesAddress(
                addresses: ['http://192.168.1.20:8080'],
                code: '4821',
              ),
            ],
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(goldenName('handheld_web_files', screen, mode)),
    );
  });
}
