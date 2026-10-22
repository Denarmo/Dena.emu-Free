// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dena_emu/src/library/card_files.dart';
import 'package:dena_emu/src/library/library_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the handheld has no picker or share sheet', () async {
    const files = CardGameFiles();
    // Add games / Add a folder open the in-app explorer instead.
    expect(files.hasPicker, isFalse);
    expect(await files.pickFiles(), isEmpty);
    expect(await files.pickFolder(importExtensions), isEmpty);
    expect(await files.takeSharedFiles(), isEmpty);
    await files.clearCache();
  });
}
