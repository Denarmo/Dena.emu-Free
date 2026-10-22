import 'package:dena_android/dena_android.dart';
import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/spike/spike_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/screen_matrix.dart';

class FakeSpikeApi extends SpikeHostApi {
  final calls = <String>[];

  @override
  Future<String?> start(String? romPath) async {
    calls.add('start');
    return null;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<int> attachTexture(int width, int height) async {
    calls.add('attachTexture $width $height');
    return 7;
  }

  @override
  Future<void> detachTexture() async => calls.add('detachTexture');

  @override
  Future<String> metrics() async =>
      '{"frames":120,"input_to_post_ms":{"p50":21.5,"p95":30.2,"max":33.0},'
      '"present_ms":null,"frame_interval_ms":{"p50":16.7,"p99":17.9,"max":18.1},'
      '"missed_frames":0,"audio_xruns":0,"audio_underruns":1,'
      '"audio_buffer_ms":41.0,"audio_rate":48000}';

  @override
  Future<int> pixel(int x, int y) async => 0;
}

void main() {
  testScreens('spike screen idle', (tester, screen, mode) async {
    await tester.pumpWidget(DenaApp(home: SpikeScreen(api: FakeSpikeApi())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(DenaApp),
      matchesGoldenFile(goldenName('spike_idle', screen, mode)),
    );
  });

  testWidgets(
    'texture path starts the core, attaches a texture, shows metrics',
    (tester) async {
      final api = FakeSpikeApi();
      await tester.pumpWidget(DenaApp(home: SpikeScreen(api: api)));
      await tester.tap(find.text('Texture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start latency test ROM'));
      await tester.pumpAndSettle();
      expect(api.calls, ['start', 'attachTexture 240 160']);
      expect(find.byType(Texture), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('p95 30.2'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(api.calls.last, 'stop');
    },
  );
}
