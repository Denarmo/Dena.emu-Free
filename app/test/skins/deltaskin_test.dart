import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dena_emu/src/skins/deltaskin.dart';
import 'package:dena_emu/src/skins/skin_layout.dart';
import 'package:dena_emu/src/skins/skin_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// Our own skin description (no third-party skins in the repo).
Map<String, Object?> fixtureInfo({String id = 'app.dena.test.gba'}) => {
  'name': 'Test GBA',
  'identifier': id,
  'gameTypeIdentifier': 'com.rileytestut.delta.game.gba',
  'debug': false,
  'representations': {
    'iphone': {
      'standard': {
        'portrait': {
          'assets': {'large': 'portrait.png'},
          'mappingSize': {'width': 400, 'height': 800},
          'extendedEdges': {'top': 5, 'bottom': 5, 'left': 5, 'right': 5},
          'screens': [
            {
              'outputFrame': {'x': 0, 'y': 40, 'width': 400, 'height': 267},
            },
          ],
          'items': [
            {
              'inputs': {
                'up': 'up',
                'down': 'down',
                'left': 'left',
                'right': 'right',
              },
              'frame': {'x': 20, 'y': 480, 'width': 140, 'height': 140},
            },
            {
              'inputs': ['a'],
              'frame': {'x': 300, 'y': 500, 'width': 70, 'height': 70},
              'extendedEdges': {'top': 0, 'bottom': 0, 'left': 0, 'right': 0},
            },
            {
              'inputs': ['a', 'b'],
              'frame': {'x': 250, 'y': 600, 'width': 50, 'height': 50},
            },
            {
              'inputs': ['menu'],
              'frame': {'x': 180, 'y': 740, 'width': 40, 'height': 40},
            },
          ],
        },
      },
      'edgeToEdge': {
        'portrait': {
          'assets': {'resizable': 'tall.pdf'},
          'mappingSize': {'width': 400, 'height': 870},
          'items': [],
        },
      },
    },
    'ipad': {
      'standard': {
        'landscape': {
          'assets': {'resizable': 'pad.pdf'},
          'mappingSize': {'width': 1024, 'height': 768},
          'translucent': true,
          'items': [],
        },
      },
    },
  },
};

/// A 1x1 transparent PNG.
final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==',
);

List<int> zipSkin(Map<String, Object?> info, {String folder = ''}) {
  final a = Archive()
    ..addFile(
      ArchiveFile.bytes('${folder}info.json', utf8.encode(jsonEncode(info))),
    )
    ..addFile(ArchiveFile.bytes('${folder}portrait.png', pngBytes));
  return ZipEncoder().encodeBytes(a);
}

void main() {
  test('parses items, edges, screens and assets', () {
    final skin = parseDeltaSkinInfo(fixtureInfo());
    expect(skin.gameType, 'gba');
    expect(skin.name, 'Test GBA');
    final rep = skin.representations['iphone']!['standard']!['portrait']!;
    expect(rep.layout.mappingSize, const Size(400, 800));
    expect(rep.layout.screen, const Rect.fromLTWH(0, 40, 400, 267));
    expect(rep.bestPng, 'portrait.png');
    final items = rep.layout.items;
    expect(items.map((i) => i.kind), [
      SkinItemKind.dpad,
      SkinItemKind.button,
      SkinItemKind.button,
      SkinItemKind.menu,
    ]);
    expect(items[0].extended, const EdgeInsets.all(5));
    expect(items[1].extended, EdgeInsets.zero);
    expect(items[2].inputs, ['a', 'b']);
    // The combo presses both buttons.
    final s = touchState(rep.layout, {1: const Offset(275, 625)});
    expect(s.mask, 1 << RetroPad.a | 1 << RetroPad.b);
  });

  test('selection follows device, screen shape and orientation', () {
    final skin = parseDeltaSkinInfo(fixtureInfo());
    final iphone = skin.representations['iphone']!;
    expect(
      skin.pick(const Size(412, 915), tablet: false),
      same(iphone['edgeToEdge']!['portrait']),
    );
    expect(
      skin.pick(const Size(400, 700), tablet: false),
      same(iphone['standard']!['portrait']),
    );
    // Tablet in landscape: the iPad layout.
    expect(
      skin.pick(const Size(1280, 800), tablet: true),
      same(skin.representations['ipad']!['standard']!['landscape']),
    );
    // Phone in landscape has no iPhone landscape: falls back to iPad landscape.
    expect(
      skin.pick(const Size(915, 412), tablet: false),
      same(skin.representations['ipad']!['standard']!['landscape']),
    );
  });

  test('rejects bad archives and unknown systems', () {
    expect(() => readDeltaSkin([1, 2, 3]), throwsA(isA<SkinFormatException>()));
    final noInfo = ZipEncoder().encodeBytes(
      Archive()..addFile(ArchiveFile.bytes('a.png', pngBytes)),
    );
    expect(() => readDeltaSkin(noInfo), throwsA(isA<SkinFormatException>()));
    expect(
      () => parseDeltaSkinInfo({
        ...fixtureInfo(),
        'gameTypeIdentifier': 'com.example.wonderswan',
      }),
      throwsA(isA<SkinFormatException>()),
    );
    expect(skinSystems('gbc'), ['gb', 'gbc']);
  });

  test('N64 skins get a thumbstick and RetroPad input names', () {
    final info = fixtureInfo();
    info['gameTypeIdentifier'] = 'com.rileytestut.delta.game.n64';
    final portrait =
        ((info['representations']! as Map)['iphone']['standard']['portrait']
            as Map);
    portrait['items'] = [
      {
        'thumbstick': {'name': 'stick.png', 'width': 40, 'height': 40},
        'inputs': {
          'up': 'analogStickUp',
          'down': 'analogStickDown',
          'left': 'analogStickLeft',
          'right': 'analogStickRight',
        },
        'frame': {'x': 20, 'y': 480, 'width': 140, 'height': 140},
      },
      {
        'inputs': ['a', 'z', 'cUp'],
        'frame': {'x': 300, 'y': 500, 'width': 70, 'height': 70},
      },
    ];
    final skin = parseDeltaSkinInfo(info);
    final items =
        skin.representations['iphone']!['standard']!['portrait']!.layout.items;
    expect(items[0].kind, SkinItemKind.thumbstick);
    expect(items[0].inputs, ['leftstick']);
    expect(items[1].inputs, ['b', 'l2', 'cup']);
  });

  test('store installs, activates, finds artwork and deletes', () async {
    final dir = Directory.systemTemp.createTempSync('dena_skins');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'test.deltaskin'))
      ..writeAsBytesSync(zipSkin(fixtureInfo(), folder: 'Test/'));
    final rasterized = <String>[];
    final store = SkinStore(
      p.join(dir.path, 'data'),
      rasterize: (pdf, w, h, out) async {
        rasterized.add('${p.basename(pdf)} $w x $h');
        File(out).writeAsBytesSync(pngBytes);
        return out;
      },
    );
    final s = await store.install(file);
    expect((await store.list()).single.skin.identifier, 'app.dena.test.gba');
    expect(await store.active('gba'), isNull);
    await store.setActive('gba', s.skin.identifier);
    expect((await store.active('gba'))!.skin.name, 'Test GBA');

    final iphone = s.skin.representations['iphone']!;
    final png = await store.artwork(
      s,
      iphone['standard']!['portrait']!,
      400,
      800,
    );
    expect(p.basename(png!.path), 'portrait.png');
    final pdf = await store.artwork(
      s,
      iphone['edgeToEdge']!['portrait']!,
      412,
      896,
    );
    expect(pdf, isNotNull);
    await store.artwork(s, iphone['edgeToEdge']!['portrait']!, 412, 896);
    expect(rasterized, ['tall.pdf 412 x 896']); // cached the second time

    await store.delete(s);
    expect(await store.list(), isEmpty);
    expect(await store.active('gba'), isNull);
  });
}
