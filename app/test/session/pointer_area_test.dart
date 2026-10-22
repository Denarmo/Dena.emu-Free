import 'package:dena_emu/src/session/pointer_area.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const lower = Rect.fromLTRB(0, 0.5, 1, 1);
  const size = Size(256, 384);

  test('the lower screen maps to pointer units; the top is ignored', () {
    expect(pointerFor(const Offset(128, 192), size, lower), (0, 0));
    expect(pointerFor(const Offset(0, 384), size, lower), (-0x7fff, 0x7fff));
    expect(pointerFor(const Offset(256, 288), size, lower), (0x7fff, 0x4000));
    expect(pointerFor(const Offset(128, 100), size, lower), isNull);
  });

  testWidgets('touches press, drag and release the pointer', (tester) async {
    final events = <(int, int, bool)>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 256,
            height: 384,
            child: PointerArea(
              onPointer: (x, y, down) => events.add((x, y, down)),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    // Top screen: nothing.
    await tester.tapAt(const Offset(100, 50));
    expect(events, isEmpty);

    final g = await tester.startGesture(const Offset(128, 288));
    await g.moveTo(const Offset(256, 288));
    await g.up();
    expect(events.first, (0, 0x4000, true));
    expect(events[events.length - 2], (0x7fff, 0x4000, true));
    expect(events.last, (0x7fff, 0x4000, false));
  });
}
