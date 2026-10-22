// The handheld embedder sends Flutter key ids from a C header; they must
// match the framework's. Spec: docs/specs/embedder.md (Input)
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('embedder key ids match the framework', () {
    final header = File('../shells/linux/include/dena/embedder_core.h')
        .readAsStringSync();
    int define(String name) {
      final m = RegExp('#define $name (0x[0-9a-fA-F]+)ULL').firstMatch(header);
      expect(m, isNotNull, reason: name);
      return int.parse(m!.group(1)!.substring(2), radix: 16);
    }

    const logical = {
      'ARROW_DOWN': LogicalKeyboardKey.arrowDown,
      'ARROW_LEFT': LogicalKeyboardKey.arrowLeft,
      'ARROW_RIGHT': LogicalKeyboardKey.arrowRight,
      'ARROW_UP': LogicalKeyboardKey.arrowUp,
      'GAME_A': LogicalKeyboardKey.gameButtonA,
      'GAME_B': LogicalKeyboardKey.gameButtonB,
      'GAME_LEFT1': LogicalKeyboardKey.gameButtonLeft1,
      'GAME_LEFT2': LogicalKeyboardKey.gameButtonLeft2,
      'GAME_MODE': LogicalKeyboardKey.gameButtonMode,
      'GAME_RIGHT1': LogicalKeyboardKey.gameButtonRight1,
      'GAME_RIGHT2': LogicalKeyboardKey.gameButtonRight2,
      'GAME_SELECT': LogicalKeyboardKey.gameButtonSelect,
      'GAME_START': LogicalKeyboardKey.gameButtonStart,
      'GAME_THUMB_LEFT': LogicalKeyboardKey.gameButtonThumbLeft,
      'GAME_THUMB_RIGHT': LogicalKeyboardKey.gameButtonThumbRight,
      'GAME_X': LogicalKeyboardKey.gameButtonX,
      'GAME_Y': LogicalKeyboardKey.gameButtonY,
    };
    for (final e in logical.entries) {
      expect(define('DENA_LOGICAL_${e.key}'), e.value.keyId, reason: e.key);
    }

    const physical = {
      'ARROW_DOWN': PhysicalKeyboardKey.arrowDown,
      'ARROW_LEFT': PhysicalKeyboardKey.arrowLeft,
      'ARROW_RIGHT': PhysicalKeyboardKey.arrowRight,
      'ARROW_UP': PhysicalKeyboardKey.arrowUp,
    };
    for (final e in physical.entries) {
      expect(define('DENA_PHYSICAL_${e.key}'), e.value.usbHidUsage);
    }
    // Game buttons: base + the logical id's low byte.
    final base = define('DENA_PHYSICAL_GAME_BASE');
    expect(
      base | (LogicalKeyboardKey.gameButtonA.keyId & 0xff),
      PhysicalKeyboardKey.gameButtonA.usbHidUsage,
    );
    expect(
      base | (LogicalKeyboardKey.gameButtonMode.keyId & 0xff),
      PhysicalKeyboardKey.gameButtonMode.usbHidUsage,
    );
    expect(
      base | (LogicalKeyboardKey.gameButtonThumbRight.keyId & 0xff),
      PhysicalKeyboardKey.gameButtonThumbRight.usbHidUsage,
    );
  });
}
