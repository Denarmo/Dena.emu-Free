// SPDX-License-Identifier: GPL-3.0-or-later
// Game files on Windows and Linux PCs: the system's own file and folder
// dialogs. Spec: docs/specs/desktop-library.md
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:path/path.dart' as p;

import 'library_scope.dart';

/// [GameFileSource] with the native dialogs (Windows' file dialog, GTK's
/// file chooser, the file-chooser portal inside the Flatpak). Picked files
/// are the user's own: nothing here is a temporary copy, so [clearCache]
/// deletes nothing.
class DesktopGameFiles implements GameFileSource {
  DesktopGameFiles([FileSelectorPlatform? dialogs]) : _dialogs = dialogs;

  final FileSelectorPlatform? _dialogs;
  FileSelectorPlatform get _platform =>
      _dialogs ?? FileSelectorPlatform.instance;

  @override
  bool get hasPicker => true;

  @override
  Future<List<String>> pickFiles() async {
    final files = await _platform.openFiles(confirmButtonText: 'Add');
    return [for (final f in files) f.path];
  }

  /// A folder the user chose, or null when they cancelled.
  Future<String?> pickDirectory() => _platform.getDirectoryPathWithOptions(
    const FileDialogOptions(confirmButtonText: 'Add folder'),
  );

  @override
  Future<List<String>> pickFolder(List<String> extensions) async {
    final dir = await pickDirectory();
    if (dir == null) return const [];
    return filesWithExtensions(Directory(dir), extensions);
  }

  @override
  Future<List<String>> takeSharedFiles() async => const [];

  @override
  Future<void> clearCache() async {}
}

/// Every file under [dir] (not in hidden folders) whose name ends with one
/// of [extensions], sorted.
Future<List<String>> filesWithExtensions(
  Directory dir,
  List<String> extensions,
) async {
  final out = <String>[];
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.split(p.relative(e.path, from: dir.path));
      if (rel.any((s) => s.startsWith('.'))) continue;
      final name = p.basename(e.path).toLowerCase();
      if (extensions.any(name.endsWith)) out.add(e.path);
    }
  } on FileSystemException {
    // Keep what was found.
  }
  return out..sort();
}
