import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/session/session_screen.dart' show systemAspect;
import 'package:dena_emu/src/skins/deltaskin.dart';
import 'package:dena_emu/src/skins/skin_layout.dart';
import 'package:dena_emu/src/skins/skin_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

Future<List<int>> _asset(String asset) => File(asset).readAsBytes();

/// Inputs each system's skin must offer (besides the D-pad or stick).
const _required = {
  'nes': ['a', 'b', 'start', 'select'],
  'snes': ['a', 'b', 'x', 'y', 'l', 'r', 'start', 'select'],
  'gb': ['a', 'b', 'start', 'select'],
  'gbc': ['a', 'b', 'start', 'select'],
  'gba': ['a', 'b', 'l', 'r', 'start', 'select'],
  // N64 names after renaming to RetroPad (n64.md).
  'n64': ['b', 'y', 'l', 'r', 'l2', 'start', 'cup', 'cdown', 'cleft', 'cright'],
  'nds': ['a', 'b', 'x', 'y', 'l', 'r', 'start', 'select'],
  'psx': ['a', 'b', 'x', 'y', 'l', 'r', 'l2', 'r2', 'start', 'select'],
  'psp': ['a', 'b', 'x', 'y', 'l', 'r', 'start', 'select'],
  'pico8': ['a', 'b', 'start'],
};

/// The console each skin family is for (variants are `<family>_<name>`).
const _systemOf = {
  'nes': 'nes',
  'snes': 'snes',
  'gb': 'gb',
  'gbc': 'gbc',
  'gba': 'gba',
  'n64': 'n64',
  'nds': 'nds',
  'psx': 'psx',
  'psp': 'psp',
};

void main() {
  for (final MapEntry(key: name, value: defaults) in bundledSkins.entries) {
    test('bundled $name skin is complete', () {
      final bytes = File('assets/skins/$name.deltaskin').readAsBytesSync();
      final (:skin, :archive) = readDeltaSkin(bytes);
      expect(skin.identifier, 'com.denaemu.skins.$name');
      final systems = defaults.isEmpty
          ? [_systemOf[name.split('_').first]!]
          : defaults;
      for (final sys in systems) {
        expect(skinSystems(skin.gameType), contains(sys));
      }
      final files = {for (final f in archive.files) f.name};
      var count = 0;
      for (final displays in skin.representations.values) {
        for (final orients in displays.values) {
          for (final rep in orients.values) {
            count++;
            final l = rep.layout;
            expect(files, contains(rep.bestPng));
            final aspect = l.screen.width / l.screen.height;
            expect(aspect, closeTo(systemAspect[systems.first]!, 0.01));
            final bounds = Offset.zero & l.mappingSize;
            final inputs = <String>{};
            for (final item in l.items) {
              expect(bounds.contains(item.frame.topLeft), isTrue);
              expect(
                bounds.contains(item.frame.bottomRight - const Offset(1, 1)),
                isTrue,
              );
              expect(item.frame.overlaps(l.screen), isFalse);
              inputs.addAll(item.inputs);
            }
            expect(inputs, containsAll(_required[systems.first]!));
            expect(
              l.items.where((i) => i.kind == SkinItemKind.menu),
              hasLength(1),
            );
            final left = systems.first == 'n64'
                ? SkinItemKind.thumbstick
                : SkinItemKind.dpad;
            expect(l.items.where((i) => i.kind == left), hasLength(1));
          }
        }
      }
      expect(count, 4);
      // Phones in both orientations, tall and not.
      for (final size in const [
        Size(412, 915),
        Size(915, 412),
        Size(360, 640),
        Size(640, 360),
      ]) {
        expect(skin.pick(size, tablet: false), isNotNull);
      }
      // Pressing the centre of a face button reaches the core.
      final rep = skin.pick(const Size(412, 915), tablet: false)!;
      final a = rep.layout.items.firstWhere(
        (i) => i.inputs.contains(systems.first == 'n64' ? 'b' : 'a'),
      );
      final state = touchState(rep.layout, {1: a.frame.center});
      expect(state.mask, isNonZero);
    });
  }

  test('installBundled sets defaults once and keeps user choices', () async {
    final dir = Directory.systemTemp.createTempSync('dena_bundled');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SkinStore(dir.path);
    await store.setActive('snes', 'user.chosen.snes');
    await store.installBundled(_asset);

    final ids = await store.activeIds();
    expect(ids['nes'], 'com.denaemu.skins.nes');
    expect(ids['gb'], 'com.denaemu.skins.gb');
    expect(ids['gbc'], 'com.denaemu.skins.gbc');
    expect(ids['snes'], 'user.chosen.snes');
    // Alternate editions are installed but not made active.
    expect(ids.values, isNot(contains('com.denaemu.skins.psp_blue')));
    final list = await store.list();
    expect(list, hasLength(bundledSkins.length));
    expect(list.every((s) => s.bundled), isTrue);

    // Switching to the built-in controls survives a restart.
    await store.setActive('nes', null);
    await store.installBundled(_asset);
    expect((await store.activeIds())['nes'], isNull);
    final index = jsonDecode(
      File(p.join(dir.path, 'skins', 'index.json')).readAsStringSync(),
    );
    expect(index['bundled'], bundledSkinsVersion);
  });
}
