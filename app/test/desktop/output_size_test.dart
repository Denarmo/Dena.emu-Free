import 'package:dena_emu/src/desktop/output_size.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('reports the picture size in physical pixels once per change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final sent = <(int, int)>[];
    Widget app(double aspect) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: DesktopOutputSize(
            sink: (w, h) => sent.add((w, h)),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(4 / 3));
    expect(sent, [(2880, 2160)]);
    await tester.pumpWidget(app(4 / 3));
    expect(sent.length, 1);
    await tester.pumpWidget(app(16 / 9));
    expect(sent.last, (3840, 2160));
  });
}
