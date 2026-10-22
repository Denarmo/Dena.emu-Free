// Spec: docs/specs/texture-packs.md: folders, per-game choices, the links
// into the cores' folders, the Settings page by D-pad, goldens.
import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/desktop/texture_packs.dart';
import 'package:dena_emu/src/desktop/tv_layout.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late Directory root, bios;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dena_textures');
    root = Directory(p.join(dir.path, 'Textures'));
    bios = Directory(p.join(dir.path, 'Bios'));
    file = File(p.join(dir.path, 'data', 'texture_packs.json'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  TexturePacks packs({TexturePackSink? sink, FolderOpener? opener}) =>
      TexturePacks.load(
        root: root,
        biosDir: bios,
        file: file,
        sink: sink,
        opener: opener ?? (_) async {},
      );

  const n64 = (sha1: 'n1', system: 'n64', path: '/r/Kart.z64');
  const psp = (sha1: 'p1', system: 'psp', path: '/r/Patapon.iso');
  const ps1 = (sha1: 's1', system: 'psx', path: '/r/Crash (USA).cue');
  const gba = (sha1: 'g1', system: 'gba', path: '/r/a.gba');

  void addFile(String path) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync('x');

  test('only N64, PS1, PSP and Dreamcast take packs', () {
    expect(
      [
        'n64',
        'psx',
        'psp',
        'dreamcast',
        'gba',
        'snes',
        'saturn',
      ].where(TexturePacks.supports),
      ['n64', 'psx', 'psp', 'dreamcast'],
    );
    expect(packs().enabledFor(gba), isFalse);
  });

  test('ensureFolders makes one folder per system; packs count', () {
    final t = packs()..ensureFolders();
    for (final s in ['n64', 'psx', 'psp', 'dreamcast']) {
      expect(Directory(p.join(root.path, s)).existsSync(), isTrue);
      expect(t.packCount(s), 0);
    }
    Directory(p.join(root.path, 'psp', 'UCUS98612')).createSync();
    addFile(p.join(root.path, 'psp', 'ULUS10041', 'textures.ini'));
    expect(t.packCount('psp'), 2);
  });

  test('off until the folder has files, then on by default', () {
    final t = packs()..ensureFolders();
    expect(t.enabledFor(n64), isFalse);
    // An empty pack folder still counts as nothing.
    Directory(p.join(root.path, 'n64', 'KART')).createSync();
    expect(t.enabledFor(n64), isFalse);
    addFile(p.join(root.path, 'n64', 'KART', 'deep', 'a.png'));
    expect(t.enabledFor(n64), isTrue);
    expect(t.enabledFor(psp), isFalse);
  });

  test('the per-game choice is saved, loaded and wins', () {
    addFile(p.join(root.path, 'n64', 'KART.hts'));
    final t = packs();
    var notified = 0;
    t.addListener(() => notified++);
    t.setGame('n1', false);
    t.setGame('n1', false); // no change, no write
    expect(notified, 1);
    expect(t.enabledFor(n64), isFalse);
    final again = packs();
    expect(again.choiceFor('n1'), isFalse);
    expect(again.enabledFor(n64), isFalse);
    again.setGame('p1', true);
    expect(packs().enabledFor(psp), isTrue);
  });

  test('a damaged file means no choices', () {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync('{nope');
    expect(packs().choiceFor('n1'), isNull);
    file.writeAsStringSync('{"games": {"n1": "yes", "p1": false}}');
    final t = packs();
    expect(t.choiceFor('n1'), isNull);
    expect(t.choiceFor('p1'), isFalse);
  });

  test('each core gets its own folder under Bios', () {
    final t = packs();
    expect(
      t.coreFolder(n64),
      p.join(bios.path, 'Mupen64plus', 'hires_texture'),
    );
    expect(t.coreFolder(psp), p.join(bios.path, 'PSP', 'TEXTURES'));
    expect(
      t.coreFolder((sha1: 'd', system: 'dreamcast', path: '/r/x.gdi')),
      p.join(bios.path, 'dc', 'textures'),
    );
    expect(
      t.coreFolder(ps1),
      p.join(bios.path, 'Crash (USA)-texture-replacements'),
    );
  });

  test('a PS1 pack is per disc, under either name', () {
    final t = packs();
    expect(t.gameFolder(ps1).path, p.join(root.path, 'psx', 'Crash (USA)'));
    Directory(p.join(root.path, 'psx', 'Crash (USA)-texture-replacements'))
        .createSync(recursive: true);
    expect(
      t.gameFolder(ps1).path,
      p.join(root.path, 'psx', 'Crash (USA)-texture-replacements'),
    );
    // Another disc's pack does not turn this one on.
    addFile(p.join(root.path, 'psx', 'Spyro', 'a.png'));
    expect(t.enabledFor(ps1), isFalse);
  });

  test('prepare links the core folder and tells the host', () {
    final sent = <bool>[];
    final t = packs(sink: sent.add);
    addFile(p.join(root.path, 'psp', 'ULUS10041', 'a.png'));
    expect(t.prepare(psp), isTrue);
    final link = t.coreFolder(psp);
    expect(FileSystemEntity.isLinkSync(link), isTrue);
    expect(File(p.join(link, 'ULUS10041', 'a.png')).existsSync(), isTrue);
    // Again: the link is kept.
    expect(t.prepare(psp), isTrue);
    t.setGame('p1', false);
    expect(t.prepare(psp), isFalse);
    t.reset();
    expect(sent, [true, true, false, false]);
    // A game without a pack never links.
    expect(t.prepare(n64), isFalse);
    expect(
      FileSystemEntity.typeSync(t.coreFolder(n64)),
      FileSystemEntityType.notFound,
    );
  }, skip: Platform.isWindows ? 'junctions need a real Windows run' : null);

  group('linkFolder', () {
    late String target, link;
    setUp(() {
      target = p.join(dir.path, 'target');
      link = p.join(dir.path, 'core', 'packs');
    });

    test('creates the target and the link', () {
      expect(linkFolder(link, target), isNull);
      expect(Directory(target).existsSync(), isTrue);
      expect(Link(link).targetSync(), p.absolute(target));
    });

    test('replaces a link that points elsewhere', () {
      Directory(p.dirname(link)).createSync(recursive: true);
      Link(link).createSync(dir.path);
      expect(linkFolder(link, target), isNull);
      expect(Link(link).targetSync(), p.absolute(target));
    });

    test('swaps an empty real folder for the link', () {
      Directory(link).createSync(recursive: true);
      expect(linkFolder(link, target), isNull);
      expect(FileSystemEntity.isLinkSync(link), isTrue);
    });

    test('leaves a folder with packs in it alone', () {
      addFile(p.join(link, 'GAME', 'a.png'));
      expect(linkFolder(link, target), isNull);
      expect(FileSystemEntity.isLinkSync(link), isFalse);
      expect(File(p.join(link, 'GAME', 'a.png')).existsSync(), isTrue);
    });

    test('a file in the way is an error and packs stay off', () {
      addFile(link);
      expect(linkFolder(link, target), contains('in the way'));
      final sent = <bool>[];
      final t = TexturePacks(
        root: root,
        biosDir: bios,
        sink: sent.add,
        games: {'p1': true},
      );
      addFile(p.join(bios.path, 'PSP', 'TEXTURES'));
      expect(t.prepare(psp), isFalse);
      expect(sent, [false]);
    });
  }, skip: Platform.isWindows ? 'junctions need a real Windows run' : null);

  group('Settings', () {
    testWidgets('the row counts packs and opens the page', (tester) async {
      final t = packs()..ensureFolders();
      addFile(p.join(root.path, 'n64', 'KART.hts'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TexturePacksTile(packs: t)),
        ),
      );
      expect(find.text('1 >'), findsOneWidget);
      await tester.tap(find.text('TEXTURE PACKS'));
      await tester.pumpAndSettle();
      expect(find.byType(TexturePacksPage), findsOneWidget);
      expect(find.text('1 PACK'), findsOneWidget);
      expect(find.text('EMPTY'), findsNWidgets(3));
    });

    testWidgets('OPEN FOLDER by D-pad and A opens each system', (tester) async {
      final opened = <String>[];
      final t = packs(opener: (path) async => opened.add(path));
      await tester.pumpWidget(MaterialApp(home: TexturePacksPage(packs: t)));
      await tester.pumpAndSettle();
      // The folder is created with real file IO before it opens.
      Future<void> io() => tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await io();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
      await io();
      await tester.pumpAndSettle();
      expect(opened, [p.join(root.path, 'n64'), p.join(root.path, 'psp')]);
    });

    for (final (name, size, tv) in [
      ('640x480', const Size(640, 480), false),
      ('1280x720', const Size(1280, 720), false),
      ('tv_1920x1080', const Size(1920, 1080), true),
    ]) {
      testWidgets('golden $name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // A fixed folder so the path line is the same on every machine.
        final t = TexturePacks(
          root: Directory(p.join(dir.path, 'Textures')),
          biosDir: bios,
        )..ensureFolders();
        addFile(p.join(dir.path, 'Textures', 'psp', 'ULUS10041', 'a.png'));
        addFile(p.join(dir.path, 'Textures', 'n64', 'KART.hts'));
        Directory(p.join(dir.path, 'Textures', 'n64', 'ZELDA')).createSync();
        final shown = _ShownPath(t, r'C:\Users\you\AppData\Roaming\Dena.emu');
        final page = TexturePacksPage(packs: shown);
        await tester.pumpWidget(
          DenaApp(home: tv ? TvScale(enabled: true, child: page) : page),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byType(TexturePacksPage),
          matchesGoldenFile('goldens/texture_packs_$name.png'),
        );
      });
    }
  });
}

/// [TexturePacks] counting the real temp folders but showing a fixed root.
class _ShownPath extends TexturePacks {
  _ShownPath(this.real, String shown)
    : super(root: Directory('$shown\\Textures'), biosDir: real.biosDir);

  final TexturePacks real;

  @override
  void ensureFolders() => real.ensureFolders();

  @override
  int packCount(String system) => real.packCount(system);
}
