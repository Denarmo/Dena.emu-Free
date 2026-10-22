// SPDX-License-Identifier: GPL-3.0-or-later
// Controller mode on Windows and SteamOS: the UI driven by a gamepad, with
// the focus ring, hint bar and TV layout. Spec: docs/specs/controller-mode.md
import 'package:material_ui/material_ui.dart';

/// Which glyphs the hint bar prints (desktop.h, DENA_DESKTOP_FAMILY_*).
enum PadFamily {
  generic,
  xbox,
  playStation,
  nintendo,
  steamDeck;

  /// The family for a host value; unknown values are [generic].
  static PadFamily fromHost(int value) =>
      value >= 0 && value < values.length ? values[value] : generic;
}

/// Whether the UI is in controller mode, and the glyphs to show.
///
/// On at launch when a gamepad is there (or on a Steam Deck); a pad used or
/// plugged in later turns it on. A mouse click turns it off only when no
/// gamepad is connected, so the Deck's touch screen or a mouse next to a
/// pad never flips the layout back and forth.
class ControllerMode extends ChangeNotifier {
  ControllerMode({
    this._active = false,
    PadFamily family = PadFamily.generic,
    this.steamDeck = false,
  }) : _family = _deckGlyphs(family, steamDeck);

  /// Running on a Steam Deck: its own controls are always there.
  final bool steamDeck;
  bool _active;
  PadFamily _family;

  bool get active => _active;
  PadFamily get family => _family;

  /// A button press or stick move on a pad of [family].
  void padUsed(PadFamily family) {
    final f = _deckGlyphs(family, steamDeck);
    if (_active && f == _family) return;
    _active = true;
    _family = f;
    notifyListeners();
  }

  /// A gamepad was plugged in.
  void padConnected() {
    if (_active) return;
    _active = true;
    notifyListeners();
  }

  /// A mouse click; [padsConnected] is how many gamepads are there now.
  void mouseUsed({required int padsConnected}) {
    if (!_active || padsConnected > 0 || steamDeck) return;
    _active = false;
    notifyListeners();
  }

  // Under Steam Input the Deck's controls show up as an Xbox pad: print the
  // Deck's own glyphs for those.
  static PadFamily _deckGlyphs(PadFamily f, bool deck) =>
      deck && (f == PadFamily.xbox || f == PadFamily.generic)
      ? PadFamily.steamDeck
      : f;
}

/// Gives the UI the desktop's [ControllerMode]; absent on phones and
/// handhelds.
class ControllerScope extends InheritedNotifier<ControllerMode> {
  const ControllerScope({
    super.key,
    required ControllerMode mode,
    required super.child,
  }) : super(notifier: mode);

  static ControllerMode? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ControllerScope>()?.notifier;

  /// Whether controller mode is on (false off the desktop).
  static bool activeOf(BuildContext context) =>
      maybeOf(context)?.active ?? false;

  /// The glyphs for the hint bar (generic off the desktop).
  static PadFamily familyOf(BuildContext context) =>
      maybeOf(context)?.family ?? PadFamily.generic;
}
