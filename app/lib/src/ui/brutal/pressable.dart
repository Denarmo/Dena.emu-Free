// SPDX-License-Identifier: GPL-3.0-or-later
// The press and focus behaviour every Brutalist control shares: focusable,
// activated by tap, click, Enter, Space or A, and pressed onto its shadow.
// Spec: docs/specs/brutalist-ui.md (2.4, 3)
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// What a control looks like right now.
@immutable
class BrutalPressState {
  const BrutalPressState({
    required this.pressed,
    required this.focused,
    required this.hovered,
    required this.enabled,
  });

  /// Held down (or within the release step after it).
  final bool pressed;

  /// Has focus and the focus highlight is showing (a key or pad was used
  /// last; touch hides it).
  final bool focused;

  /// Under a mouse pointer.
  final bool hovered;

  final bool enabled;

  /// Whether the control should draw its focus look.
  bool get highlighted => focused || hovered;
}

/// Builds a control from its [BrutalPressState].
typedef BrutalPressBuilder =
    Widget Function(BuildContext context, BrutalPressState state);

/// A focusable, pressable region. Pressing is instant; letting go springs
/// back after [BrutalTokens.release] (instant when animations are off).
class BrutalPressable extends StatefulWidget {
  const BrutalPressable({
    super.key,
    required this.onPressed,
    required this.builder,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.selected,
    this.onFocusChange,
    this.mouseCursor,
  });

  /// Null disables the control.
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final BrutalPressBuilder builder;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;
  final bool? selected;
  final ValueChanged<bool>? onFocusChange;
  final MouseCursor? mouseCursor;

  @override
  State<BrutalPressable> createState() => _BrutalPressableState();
}

class _BrutalPressableState extends State<BrutalPressable> {
  bool _down = false;
  bool _focused = false;
  bool _hovered = false;
  Timer? _release;

  bool get _enabled => widget.onPressed != null;

  void _press() {
    _release?.cancel();
    if (!_down) setState(() => _down = true);
  }

  void _letGo() {
    _release?.cancel();
    if (!_down) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      setState(() => _down = false);
      return;
    }
    _release = Timer(BrutalTokens.release, () {
      if (mounted) setState(() => _down = false);
    });
  }

  void _activate() {
    if (!_enabled) return;
    // A key press shows the press as one step, as a tap does.
    _press();
    _letGo();
    widget.onPressed!();
  }

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = BrutalPressState(
      pressed: _down,
      focused: _focused,
      hovered: _hovered && _enabled,
      enabled: _enabled,
    );
    return Semantics(
      button: true,
      enabled: _enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        enabled: _enabled,
        mouseCursor:
            widget.mouseCursor ??
            (_enabled ? SystemMouseCursors.click : MouseCursor.defer),
        onShowFocusHighlight: (v) {
          if (v != _focused) setState(() => _focused = v);
          widget.onFocusChange?.call(v);
        },
        onShowHoverHighlight: (v) {
          if (v != _hovered) setState(() => _hovered = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => _activate(),
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) => _activate(),
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => _press() : null,
          onTapUp: _enabled ? (_) => _letGo() : null,
          onTapCancel: _enabled ? _letGo : null,
          onTap: widget.onPressed,
          onLongPress: widget.onLongPress,
          child: widget.builder(context, state),
        ),
      ),
    );
  }
}

/// Draws [child] on a hard shadow, moved onto it while [pressed]
/// (brutalist-ui.md 1.3, 2.4). [offset] is the shadow's offset.
class BrutalShadowBox extends StatelessWidget {
  const BrutalShadowBox({
    super.key,
    required this.pressed,
    required this.offset,
    required this.color,
    required this.child,
  });

  final bool pressed;
  final Offset offset;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Room for the shadow, so pressing never shifts the layout.
      padding: EdgeInsets.only(right: offset.dx, bottom: offset.dy),
      child: Transform.translate(
        offset: pressed ? offset : Offset.zero,
        child: DecoratedBox(
          decoration: BoxDecoration(
            boxShadow: pressed ? null : [BoxShadow(color: color, offset: offset)],
          ),
          child: child,
        ),
      ),
    );
  }
}
