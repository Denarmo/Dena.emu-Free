import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/shaders/shader_catalog.dart';
import 'package:dena_emu/src/shaders/shader_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dena_shaders'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a missing file resolves to Off', () {
    final store = ShaderStore(p.join(dir.path, 'nested'));
    expect(store.resolve('nes', 'abc'), '');
    expect(store.systemDefault('nes'), '');
    expect(store.hasGameOverride('abc'), isFalse);
  });

  test('game override > system default > Off, and it round-trips', () {
    ShaderStore(dir.path)
      ..setSystem('nes', 'crt-fast')
      ..setGame('g1', 'scanlines')
      ..setGame('g2', '');
    final again = ShaderStore(dir.path);
    expect(again.resolve('nes', 'g1'), 'scanlines');
    expect(again.resolve('nes', 'g2'), '', reason: '"" is Off for that game');
    expect(again.resolve('nes', 'g3'), 'crt-fast');
    expect(again.resolve('snes', 'g3'), '');
    expect(again.hasGameOverride('g2'), isTrue);

    again
      ..clearGame('g2')
      ..setSystem('nes', '');
    expect(ShaderStore(dir.path).resolve('nes', 'g2'), '');
    expect(ShaderStore(dir.path).hasGameOverride('g2'), isFalse);
    expect(ShaderStore(dir.path).resolve('nes', 'g1'), 'scanlines');
  });

  test('the file has the documented shape', () {
    ShaderStore(dir.path)
      ..setSystem('gb', 'dot-matrix')
      ..setGame('g1', '');
    expect(
      File(p.join(dir.path, 'shaders.json')).readAsStringSync(),
      '{"systems":{"gb":"dot-matrix"},"games":{"g1":""}}',
    );
  });

  test('upscale: game > system > default, capped per system', () {
    final store = ShaderStore(dir.path)
      ..setSystem('n64', 'crt-fast')
      ..setSystemUpscale('n64', 3)
      ..setGameUpscale('g2', 0)
      ..setSystemUpscale('psx', 4)
      ..setSystemUpscale('gba', 2);
    expect(store.resolveUpscale('n64', 'g1'), 3);
    expect(store.resolveUpscale('n64', 'g2'), 0);
    expect(store.resolveUpscale('psx', 'g1'), 2); // PSX does 2x at most
    expect(store.resolveUpscale('gba', 'g1'), 0); // native only
    expect(store.resolve('n64', 'g1'), 'crt-fast'); // shaders untouched
    store
      ..clearGameUpscale('g2')
      ..setSystemUpscale('n64', 0);
    expect(store.resolveUpscale('n64', 'g2'), 0);
    expect(store.hasGameUpscale('g2'), isFalse);
    expect(
      jsonDecode(File(p.join(dir.path, 'shaders.json')).readAsStringSync()),
      {
        'systems': {'n64': 'crt-fast'},
        'games': <String, Object>{},
        'upscale': {
          'systems': {'psx': 4, 'gba': 2},
          'games': <String, Object>{},
        },
      },
    );
    expect(maxUpscale('psp'), 4);
    expect(maxUpscale('nes'), 1);
    // GB and GBC upscale through the filter; GBA shares GB's core but stays
    // native. DS renders true 3D resolution on OpenGL ES.
    for (final s in ['gb', 'gbc']) {
      expect(maxUpscale(s), 4, reason: s);
      expect(filterUpscale(s), isTrue, reason: s);
    }
    expect(maxUpscale('gba'), 1);
    expect(filterUpscale('n64'), isFalse);
    expect(maxUpscale('nds'), 4);
    expect(filterUpscale('nds'), isFalse);
    expect(upscaleRequirement('nds'), 'OpenGL ES 3.2');
    expect(upscaleRequirement('n64'), isNull);
  });

  test('desktop factors go to 8x; phones keep 2x-4x', () {
    expect(upscaleFactors('n64', desktop: true), [2, 3, 4, 6, 8]);
    expect(upscaleFactors('psp', desktop: true), [2, 3, 4, 6, 8]);
    expect(upscaleFactors('nds', desktop: true), [2, 3, 4, 6, 8]);
    expect(upscaleFactors('psx', desktop: true), [2, 4, 8]); // Beetle PSX HW
    // No xBRZ filter on the desktop renderer: GB and GBC stay native.
    for (final s in ['gb', 'gbc', 'gba', 'nes', 'snes', 'pico8']) {
      expect(upscaleFactors(s, desktop: true), isEmpty, reason: s);
      expect(maxUpscale(s, desktop: true), 1, reason: s);
    }
    expect(filterUpscale('gb', desktop: true), isFalse);
    expect(upscaleRequirement('nds', desktop: true), isNull);
    expect(upscaleFactors('n64', desktop: false), [2, 3, 4]);
    expect(upscaleFactors('psx', desktop: false), [2]);
    expect(maxUpscale('n64', desktop: true), 8);
    // Tests run as the phone unless they say otherwise.
    expect(upscaleFactors('n64'), [2, 3, 4]);
  });

  test('desktop store keeps 8x and rounds down to an offered factor', () {
    final store = ShaderStore(dir.path, desktop: true)
      ..setSystemUpscale('n64', 8)
      ..setSystemUpscale('psx', 6)
      ..setGameUpscale('g3', 3)
      ..setSystemUpscale('gb', 4);
    expect(store.resolveUpscale('n64', 'g1'), 8);
    expect(store.systemUpscale('psx'), 4); // 2x, 4x, 8x only
    expect(store.resolveUpscale('psx', 'g3'), 2);
    expect(store.resolveUpscale('gb', 'g1'), 0);
    // The same file read by a phone caps at its own limits.
    final phone = ShaderStore(dir.path, desktop: false);
    expect(phone.resolveUpscale('n64', 'g1'), 4);
    expect(phone.resolveUpscale('psx', 'g1'), 2);
    expect(phone.resolveUpscale('gb', 'g1'), 4);
  });

  test('widescreen: game > system > off, desktop N64 and PSX only', () {
    final store = ShaderStore(dir.path, desktop: true)
      ..setSystemWidescreen('n64', true)
      ..setGameWidescreen('g2', false)
      ..setGameWidescreen('g3', true)
      ..setSystemWidescreen('psp', true);
    expect(store.resolveWidescreen('n64', 'g1'), isTrue);
    expect(store.resolveWidescreen('n64', 'g2'), isFalse);
    expect(store.resolveWidescreen('psx', 'g1'), isFalse);
    expect(store.resolveWidescreen('psx', 'g3'), isTrue);
    expect(store.resolveWidescreen('psp', 'g1'), isFalse); // no hack
    expect(store.systemWidescreen('n64'), isTrue);
    expect(store.systemWidescreen('psp'), isFalse);
    expect(store.hasGameWidescreen('g2'), isTrue);
    expect(hasWidescreen('n64', desktop: true), isTrue);
    expect(hasWidescreen('psx', desktop: true), isTrue);
    expect(hasWidescreen('nds', desktop: true), isFalse);
    expect(hasWidescreen('n64', desktop: false), isFalse);
    // Phones never turn it on, whatever the file says.
    expect(
      ShaderStore(dir.path, desktop: false).resolveWidescreen('n64', 'g1'),
      isFalse,
    );
    store
      ..clearGameWidescreen('g2')
      ..clearGameWidescreen('g3')
      ..setSystemWidescreen('psp', false);
    expect(store.resolveWidescreen('n64', 'g2'), isTrue);
    expect(store.hasGameWidescreen('g2'), isFalse);
    expect(
      jsonDecode(File(p.join(dir.path, 'shaders.json')).readAsStringSync()),
      {
        'systems': <String, Object>{},
        'games': <String, Object>{},
        'widescreen': {
          'systems': {'n64': true},
          'games': <String, Object>{},
        },
      },
    );
    // A survived reload; non-bool values are ignored.
    File(p.join(dir.path, 'shaders.json')).writeAsStringSync(
      '{"widescreen": {"systems": {"n64": "yes", "psx": true}}}',
    );
    final again = ShaderStore(dir.path, desktop: true);
    expect(again.resolveWidescreen('n64', 'g1'), isFalse);
    expect(again.resolveWidescreen('psx', 'g1'), isTrue);
  });

  test('unknown ids and damaged files are Off', () {
    final file = File(p.join(dir.path, 'shaders.json'));
    file.writeAsStringSync(
      '{"systems": {"nes": "crt-gone", "gb": 3}, "games": {"g": "nope"}}',
    );
    final store = ShaderStore(dir.path);
    expect(store.resolve('nes', 'x'), '');
    expect(store.resolve('gb', 'x'), '');
    expect(store.resolve('nes', 'g'), '');

    file.writeAsStringSync('{"systems": ');
    expect(store.resolve('nes', 'x'), '');
    file.writeAsStringSync('[]');
    expect(store.resolve('nes', 'x'), '');
    // Saving over a damaged file starts it afresh.
    store.setSystem('nes', 'crt-geom');
    expect(store.resolve('nes', 'x'), 'crt-geom');
  });

  test('catalog ids match the presets in host/shaders', () {
    final root = Directory(p.join('..', 'host', 'shaders'));
    final folders = [
      for (final d in root.listSync())
        // "_upscale" is the upscale filter, not a user shader.
        if (d is Directory && !p.basename(d.path).startsWith('_'))
          p.basename(d.path),
    ]..sort();
    expect(shaderCatalog.map((s) => s.id).toList()..sort(), folders);
    for (final id in folders) {
      expect(
        File(p.join(root.path, id, '$id.glslp')).existsSync(),
        isTrue,
        reason: '$id/$id.glslp',
      );
    }
  });

  test('suggested shaders come first for a system', () {
    final gb = shadersFor('gb');
    expect(
      [
        for (final e in gb)
          if (e.suggested) e.shader.id,
      ],
      ['sharp-bilinear', 'lcd-grid', 'lcd3x', 'dot-matrix'],
    );
    expect(gb.length, shaderCatalog.length);
    expect(gb.skipWhile((e) => e.suggested).every((e) => !e.suggested), isTrue);
    expect(shaderById('crt-geom')!.name, 'CRT (curved)');
    expect(shaderById(''), isNull);
    expect(shaderName('nope'), 'Off');
  });

  test('desktop catalog ids match host/slang-shaders', () {
    final root = Directory(p.join('..', 'host', 'slang-shaders'));
    final presets = [
      for (final f in root.listSync())
        if (f is File && f.path.endsWith('.slangp'))
          p.basenameWithoutExtension(f.path),
    ]..sort();
    expect([for (final s in desktopShaderCatalog) s.id]..sort(), presets);
    expect(shaderById('crt-royale', desktop: true)!.passes, 12);
    expect(shaderById('crt-guest-advanced', desktop: true)!.passes, 12);
    expect(shaderById('gtu', desktop: true)!.passes, 3);
    // crt-bloom is the phone's own; Royale is the desktop's.
    expect(shaderById('crt-bloom', desktop: true), isNull);
    expect(shaderById('crt-royale', desktop: false), isNull);
    expect(shaderCatalogFor(desktop: false), same(shaderCatalog));

    final nes = shadersFor('nes', desktop: true);
    expect(nes.length, desktopShaderCatalog.length);
    expect(nes.first.suggested, isTrue);
  });

  test('a desktop store keeps desktop ids, a phone store drops them', () {
    final dir = Directory.systemTemp.createTempSync('dena_shader_store');
    addTearDown(() => dir.deleteSync(recursive: true));
    final desk = ShaderStore(dir.path, desktop: true)
      ..setSystem('psx', 'crt-royale');
    expect(desk.systemDefault('psx'), 'crt-royale');
    expect(ShaderStore(dir.path, desktop: false).systemDefault('psx'), '');
    desk.setSystem('snes', 'crt-bloom');
    expect(desk.systemDefault('snes'), '');
  });
}
