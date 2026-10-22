// On-device latency spike test (Android emulator in CI, or a phone on the rig).
// Spec: docs/specs/latency-spike.md (Acceptance tests)
//   flutter test integration_test/spike_test.dart
import 'dart:convert';

import 'package:dena_android/dena_android.dart';
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/spike/spike_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const keycodeButtonA = 96; // KeyEvent.KEYCODE_BUTTON_A (positional: RetroPad B)
const keycodeX = 52; // KeyEvent.KEYCODE_X (keyboard: RetroPad A)

bool isWhite(int px) =>
    px >= 0 &&
    ((px >> 16) & 0xff) > 0xf0 &&
    ((px >> 8) & 0xff) > 0xf0 &&
    (px & 0xff) > 0xf0;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final api = SpikeHostApi();

  for (final path in ['SurfaceView', 'Texture']) {
    testWidgets('latency ROM responds to input on the $path path', (
      tester,
    ) async {
      await tester.pumpWidget(const DenaApp(home: SpikeScreen()));
      await tester.tap(find.text(path));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start latency test ROM'));
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.textContaining('Audio:'),
        findsOneWidget,
        reason: 'metrics are polled',
      );

      expect(await api.pixel(120, 80), 0, reason: 'black with no input');

      // The latency ROM reacts to RetroPad A; keyboard X maps to it.
      await api.debugDispatchKey(keycodeX, true);
      await tester.pump(const Duration(milliseconds: 300));
      final pressed = await api.pixel(120, 80);
      expect(
        isWhite(pressed),
        isTrue,
        reason: 'white while A is held (got $pressed)',
      );

      await api.debugDispatchKey(keycodeX, false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(await api.pixel(120, 80), 0, reason: 'black after release');

      // The bottom face button is RetroPad B, which the ROM ignores.
      await api.debugDispatchKey(keycodeButtonA, true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(await api.pixel(120, 80), 0);
      await api.debugDispatchKey(keycodeButtonA, false);

      await tester.pump(const Duration(seconds: 2));
      final m = jsonDecode(await api.metrics()) as Map<String, dynamic>;
      // ignore: avoid_print
      print('DENA_METRICS $path ${jsonEncode(m)}');
      expect(m['frames'] as int, greaterThan(120));
      expect(m['input_to_post_ms'], isNotNull);

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
    });
  }
}
