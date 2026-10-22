// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:dena_emu/src/shell/app_dirs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('handheldDataDir', () {
    test('is Dena/user/data on the card', () {
      final dir = handheldDataDir({
        'DENA_HANDHELD': '1',
        'DENA_CARD': '/mnt/card',
      });
      if (!Platform.isLinux) {
        expect(dir, isNull);
        return;
      }
      expect(dir?.path, p.join('/mnt/card', 'Dena', 'user', 'data'));
      expect(
        libraryDatabaseDir({'DENA_HANDHELD': '1', 'DENA_CARD': '/mnt/card'})
            ?.path,
        dir?.path,
      );
    });

    test('is null off the handheld or without a card', () {
      expect(handheldDataDir({'DENA_CARD': '/mnt/card'}), isNull);
      expect(handheldDataDir({'DENA_HANDHELD': '1'}), isNull);
      expect(handheldDataDir({'DENA_HANDHELD': '1', 'DENA_CARD': ''}), isNull);
      expect(libraryDatabaseDir(const {}), isNull);
    });
  });
}
