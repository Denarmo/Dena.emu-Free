import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// aapt's default ignore rules, which drop folders starting with "_".
const _aaptDefault =
    '!.svn:!.git:!.ds_store:!*.scc:.*:<dir>_*:!CVS:!thumbs.db:!picasa.ini:!*~';

/// Whether [name] is skipped by an aapt `ignoreAssetsPattern`: tokens split by
/// ":", "!" only silences the warning, `<dir>`/`<file>` limit the kind, and "*"
/// matches any prefix or suffix, case-insensitively.
bool _ignored(String pattern, String name, {required bool isDir}) {
  final lower = name.toLowerCase();
  for (var token in pattern.split(':')) {
    if (token.startsWith('!')) token = token.substring(1);
    if (token.startsWith('<dir>')) {
      if (!isDir) continue;
      token = token.substring(5);
    } else if (token.startsWith('<file>')) {
      if (isDir) continue;
      token = token.substring(6);
    }
    token = token.toLowerCase();
    final head = token.startsWith('*');
    final tail = token.endsWith('*') && token.length > 1;
    final core = token.substring(head ? 1 : 0, token.length - (tail ? 1 : 0));
    final hit = head && tail
        ? lower.contains(core)
        : head
            ? lower.endsWith(core)
            : tail
                ? lower.startsWith(core)
                : lower == core;
    if (hit) return true;
  }
  return false;
}

String _pattern(String gradleFile) {
  final text = File(gradleFile).readAsStringSync();
  final m = RegExp(r'ignoreAssetsPattern = "([^"]+)"').firstMatch(text);
  expect(m, isNotNull, reason: '$gradleFile sets no ignoreAssetsPattern');
  return m!.group(1)!;
}

void main() {
  // Tests run from app/.
  final repo = p.dirname(Directory.current.path);
  final shaders = Directory(p.join(repo, 'host', 'shaders'));
  final modules = [
    p.join(repo, 'app', 'android', 'app', 'build.gradle.kts'),
    p.join(repo, 'shells', 'android', 'android', 'build.gradle.kts'),
  ];

  test('the default aapt rules would drop _upscale', () {
    expect(_ignored(_aaptDefault, '_upscale', isDir: true), isTrue);
  });

  for (final module in modules) {
    test('${p.relative(module, from: repo)} packages every shader file', () {
      final pattern = _pattern(module);
      final dropped = <String>[];
      for (final e in shaders.listSync(recursive: true)) {
        final rel = p.relative(e.path, from: shaders.path);
        final isDir = e is Directory;
        if (_ignored(pattern, p.basename(rel), isDir: isDir)) dropped.add(rel);
      }
      expect(dropped, isEmpty);
      // The rest of aapt's defaults still apply.
      expect(_ignored(pattern, '.git', isDir: true), isTrue);
      expect(_ignored(pattern, 'notes.txt~', isDir: false), isTrue);
    });
  }
}
