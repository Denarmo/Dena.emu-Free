// Spec: docs/specs/controller-mode.md (TV layout)
import 'package:dena_emu/src/desktop/tv_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('scale per screen', () {
    expect(tvScale(const Size(1920, 1080)), 1.5);
    expect(tvScale(const Size(3840, 2160)), 3);
    expect(tvScale(const Size(1280, 800)), 1); // Steam Deck
    expect(tvScale(const Size(800, 600)), 1);
    expect(tvScale(const Size(2560, 1080)), 1.5); // ultrawide: by height
  });

  testWidgets('lays out at 1280x720 on a 1080p screen and taps land', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Size? inner;
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TvScale(enabled: true, child: child!),
        home: Builder(
          builder: (context) {
            inner = MediaQuery.sizeOf(context);
            return Align(
              alignment: Alignment.bottomRight,
              child: SizedBox(
                width: 100,
                height: 100,
                child: GestureDetector(onTap: () => taps++),
              ),
            );
          },
        ),
      ),
    );
    expect(inner, const Size(1280, 720));
    // The box's bottom-right corner is the screen's: 1180..1280 at 1.5x.
    await tester.tapAt(const Offset(1900, 1060));
    expect(taps, 1);
    await tester.tapAt(const Offset(1700, 1060)); // 1133 < 1180: outside
    expect(taps, 1);
  });
}
