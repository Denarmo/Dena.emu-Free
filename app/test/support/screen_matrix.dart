// Runs a widget test across every screen size and input mode the UI must
// support (CLAUDE.md §5, §7). Spec: docs/specs/ui-test-harness.md
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class ScreenSize {
  const ScreenSize(this.name, this.size, {this.pixelRatio = 1.0});
  final String name;
  final Size size; // logical pixels
  final double pixelRatio;
}

const handheld4x3 = ScreenSize('640x480', Size(640, 480));
const handheldSquare = ScreenSize('720x720', Size(720, 720));
const phone = ScreenSize('phone', Size(412, 915), pixelRatio: 2.625);

/// A desktop window or the TV layout; opt in with `sizes:`.
const desktop720 = ScreenSize('1280x720', Size(1280, 720));

const allScreenSizes = [handheld4x3, handheldSquare, phone];

enum InputMode {
  /// Touch: no focus ring.
  touch,

  /// D-pad / gamepad / keyboard: focus ring visible.
  focus,
}

/// Declares one test per (size, mode) pair, named `<description> [<size>, <mode>]`.
/// Goldens should be named with [goldenName].
void testScreens(
  String description,
  Future<void> Function(WidgetTester tester, ScreenSize screen, InputMode mode)
  body, {
  List<ScreenSize> sizes = allScreenSizes,
  List<InputMode> modes = InputMode.values,
  Object? tags,
}) {
  for (final screen in sizes) {
    for (final mode in modes) {
      testWidgets('$description [${screen.name}, ${mode.name}]', (
        tester,
      ) async {
        tester.view.physicalSize = screen.size * screen.pixelRatio;
        tester.view.devicePixelRatio = screen.pixelRatio;
        addTearDown(tester.view.reset);
        FocusManager.instance.highlightStrategy = mode == InputMode.focus
            ? FocusHighlightStrategy.alwaysTraditional
            : FocusHighlightStrategy.alwaysTouch;
        addTearDown(
          () => FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic,
        );
        await body(tester, screen, mode);
      }, tags: tags);
    }
  }
}

String goldenName(String screenName, ScreenSize screen, InputMode mode) =>
    'goldens/${screenName}_${screen.name}_${mode.name}.png';

/// Moves focus with arrow keys and activates with Enter, as a D-pad would.
Future<void> dpad(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}
