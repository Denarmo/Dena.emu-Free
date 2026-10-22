// SPDX-License-Identifier: GPL-3.0-or-later
// Handheld mode and the button-hint bar. Spec: docs/specs/handheld-ui.md
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../desktop/controller_mode.dart';
import '../ui/brutal/overlays.dart';

/// Whether the app runs as the launcher of a Linux handheld (no touch, D-pad
/// only). The SD-card launcher sets `DENA_HANDHELD=1`.
bool detectHandheld() =>
    Platform.isLinux && Platform.environment['DENA_HANDHELD'] == '1';

/// Tells screens they run on a handheld.
class Handheld extends InheritedWidget {
  const Handheld({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Handheld>()?.enabled ?? false;

  @override
  bool updateShouldNotify(Handheld old) => enabled != old.enabled;
}

/// Whether the UI is driven by buttons: on a handheld, or in controller
/// mode on Windows and SteamOS (controller-mode.md). Hint bars, the D-pad
/// leaving text fields and the on-screen keyboard follow it.
bool usesButtons(BuildContext context) =>
    Handheld.of(context) || ControllerScope.activeOf(context);

/// A face or shoulder button shown in a hint. [a] is the button that
/// confirms and [b] the one that goes back, whatever the pad prints on them.
enum HintButton {
  a('A'),
  b('B'),
  x('X'),
  y('Y'),
  l1('L1'),
  r1('R1'),
  start('START');

  const HintButton(this.glyph);

  /// The handheld's label.
  final String glyph;

  /// The label printed on a pad of [family] (controller-mode.md, Glyphs).
  String glyphFor(PadFamily family) => switch ((family, this)) {
    (PadFamily.playStation, a) => '\u2715', // cross
    (PadFamily.playStation, b) => '\u25CB', // circle
    (PadFamily.playStation, x) => '\u25A1', // square
    (PadFamily.playStation, y) => '\u25B3', // triangle
    (PadFamily.playStation, start) => 'OPTIONS',
    (PadFamily.xbox, l1) => 'LB',
    (PadFamily.xbox, r1) => 'RB',
    (PadFamily.xbox || PadFamily.steamDeck, start) => 'MENU',
    (PadFamily.nintendo, l1) => 'L',
    (PadFamily.nintendo, r1) => 'R',
    (PadFamily.nintendo, start) => '+',
    _ => glyph,
  };
}

/// One hint: buttons (shown together, e.g. L1/R1) and what they do.
typedef ButtonHint = (List<HintButton>, String);

/// The bottom bar of hints on handhelds and in controller mode (CLAUDE.md
/// §5). Screens say which hints apply; the bar is drawn as the Brutalist
/// [BrutalHintBar] with [KeyGlyph]s (brutalist-ui.md 3, 4.1).
class HintBar extends StatelessWidget {
  const HintBar({super.key, required this.hints});

  final List<ButtonHint> hints;

  static const height = BrutalHintBar.height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: LayoutBuilder(
      // Full width when the hints fit; a long list (the box options on
      // 640x480) shrinks to fit instead of overflowing.
      builder: (context, box) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.bottomRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: box.maxWidth),
          child: IntrinsicWidth(child: BrutalHintBar(hints: hints)),
        ),
      ),
    ),
  );
}

/// B goes back on every screen: pops the top route (sheet, dialog, page).
class BackIntent extends Intent {
  const BackIntent();
}

/// Arrow keys that only move focus. Put inside a [RadioGroup] so the D-pad
/// moves between options and A picks one: the group's own arrow keys pick
/// every option they pass and never leave the group.
const arrowsMoveFocus = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
    TraversalDirection.up,
  ),
  SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
    TraversalDirection.down,
  ),
  SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
    TraversalDirection.left,
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
    TraversalDirection.right,
  ),
};

/// On handhelds the D-pad always moves focus, also out of a text field
/// (there is no keyboard to move its cursor with). The app puts these below
/// the text-editing shortcuts so they win; sliders and radio groups nearer
/// the focus keep their own.
const handheldArrows = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
    TraversalDirection.up,
    ignoreTextFields: false,
  ),
  SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
    TraversalDirection.down,
    ignoreTextFields: false,
  ),
  SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
    TraversalDirection.left,
    ignoreTextFields: false,
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
    TraversalDirection.right,
    ignoreTextFields: false,
  ),
};
