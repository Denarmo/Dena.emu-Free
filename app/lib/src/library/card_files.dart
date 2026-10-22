// SPDX-License-Identifier: GPL-3.0-or-later
// Game files on a handheld. Spec: docs/specs/handheld-session.md
import 'library_scope.dart';

/// [GameFileSource] for the Linux handheld: there is no system picker or
/// share sheet, so Add games and Add a folder open the in-app explorer
/// (file_explorer.dart) and these calls find nothing instead of calling the
/// Android shell. Games on the card's `Roms/` also join the library in place
/// ([scanCardRoms], card_library.dart).
class CardGameFiles implements GameFileSource {
  const CardGameFiles();

  @override
  bool get hasPicker => false;

  @override
  Future<List<String>> pickFiles() async => const [];

  @override
  Future<List<String>> pickFolder(List<String> extensions) async => const [];

  @override
  Future<List<String>> takeSharedFiles() async => const [];

  @override
  Future<void> clearCache() async {}
}
