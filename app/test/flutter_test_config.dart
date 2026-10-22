// Golden images are recorded on one OS and compared on others (CI runs Linux),
// so allow a small per-image pixel difference from font anti-aliasing.
// Spec: docs/specs/ui-test-harness.md
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dena_emu/src/library/foil.dart';
import 'package:dena_emu/src/shell/platform_features.dart';

// 2.5 %: text edges differ by OS; dense 640x480 screens reach 1.5 % on Windows,
// and the stash's rotated cover text reaches 2.02 % on Linux.
const double goldenTolerance = 0.025;

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FoilTilt.animate = false;
  // Tests drive the Android UI with fakes on any host.
  hasAndroidShell = true;
  final previous = goldenFileComparator;
  if (previous is LocalFileComparator) {
    goldenFileComparator = _TolerantComparator(previous.basedir);
  }
  await testMain();
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(Uri basedir) : super(basedir.resolve('placeholder.dart'));

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= goldenTolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
