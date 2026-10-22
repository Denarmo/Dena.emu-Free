// SPDX-License-Identifier: GPL-3.0-or-later
// Brutalist buttons: hard rectangles on a solid shadow, the hold-to-confirm
// hazard button, and the same look as ButtonStyles for stock buttons.
// Spec: docs/specs/brutalist-ui.md (3: BrutalButton, HoldToConfirm)
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'pressable.dart';
import 'shapes.dart';
import 'tokens.dart';

/// A [BrutalButton]'s colours.
enum BrutalButtonVariant {
  /// Panel fill, ink text.
  plain,

  /// Electric blue, white text: the primary action (PLAY, RESUME).
  primary,

  /// Yellow, black text.
  focus,

  /// Black with yellow text (QUIT).
  dark,

  /// Panel with a striped edge and danger text (DELETE).
  hazard,
}

/// Fill and text colour of [variant] in [t], unfocused.
(Color, Color) brutalVariantColors(BrutalTokens t, BrutalButtonVariant variant) =>
    switch (variant) {
      BrutalButtonVariant.plain => (t.panel, t.ink),
      BrutalButtonVariant.primary => (t.primary, t.onPrimary),
      BrutalButtonVariant.focus => (t.focus, t.onFocus),
      BrutalButtonVariant.dark => (const Color(0xFF000000), t.focus),
      BrutalButtonVariant.hazard => (t.panel, t.danger),
    };

/// A hard rectangle on a hard shadow; pressing moves it onto the shadow.
/// Optional leading [icon], [index] (`01`) and right-hand [value] (`[3 ON]`).
/// Focused, it fills yellow (a yellow button gets a blue outline instead)
/// and on pad devices shows a `<-` marker outside its right edge.
class BrutalButton extends StatelessWidget {
  const BrutalButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = BrutalButtonVariant.plain,
    this.icon,
    this.index,
    this.value,
    this.expand = false,
    this.focusNode,
    this.autofocus = false,
    this.onLongPress,
    this.selected = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final BrutalButtonVariant variant;
  final IconData? icon;
  final String? index;
  final String? value;

  /// Fill the available width, label left and value right.
  final bool expand;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Drawn already pressed (a chosen tab or option).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPressable(
      onPressed: onPressed,
      onLongPress: onLongPress,
      focusNode: focusNode,
      autofocus: autofocus,
      selected: selected,
      semanticLabel: label,
      builder: (context, s) => BrutalButtonFace(
        tokens: t,
        state: s,
        label: label,
        variant: variant,
        icon: icon,
        index: index,
        value: value,
        expand: expand,
        selected: selected,
      ),
    );
  }
}

/// The drawing of a [BrutalButton] in a given [state]; [HoldToConfirm] and
/// tabs reuse it.
class BrutalButtonFace extends StatelessWidget {
  const BrutalButtonFace({
    super.key,
    required this.tokens,
    required this.state,
    required this.label,
    this.variant = BrutalButtonVariant.plain,
    this.icon,
    this.index,
    this.value,
    this.expand = false,
    this.selected = false,
    this.progress,
  });

  final BrutalTokens tokens;
  final BrutalPressState state;
  final String label;
  final BrutalButtonVariant variant;
  final IconData? icon;
  final String? index;
  final String? value;
  final bool expand;
  final bool selected;

  /// A hold's progress (0 to 1), filled left to right in danger.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    var (fill, text) = brutalVariantColors(t, variant);
    if (!state.enabled) {
      fill = t.muted;
      text = t.mutedText;
    }
    final focusIsFill = fill == t.focus;
    final lit = state.enabled && state.highlighted;
    if (lit && !focusIsFill) {
      fill = t.focus;
      text = t.onFocus;
    }
    final style = t.label.copyWith(color: text);
    final pad = t.density == BrutalDensity.handheld
        ? BrutalTokens.s2
        : BrutalTokens.s3;
    final filled = progress ?? 0;
    Widget face = Container(
      constraints: BoxConstraints(minHeight: t.buttonHeight),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(
          color: lit && focusIsFill ? t.primary : t.ink,
          width: BrutalTokens.border,
        ),
      ),
      child: Stack(
        children: [
          if (filled > 0)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: filled.clamp(0, 1),
                child: ColoredBox(color: t.danger),
              ),
            ),
          if (variant == BrutalButtonVariant.hazard)
            const Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 10,
              child: HazardStripes(),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              variant == BrutalButtonVariant.hazard ? pad + 10 : pad,
              BrutalTokens.s1,
              pad,
              BrutalTokens.s1,
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (index != null) ...[
                  Text(
                    index!,
                    style: t.small.copyWith(
                      color: text.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(width: BrutalTokens.s2),
                ],
                if (icon != null) ...[
                  Icon(icon, size: BrutalTokens.iconSize, color: text),
                  const SizedBox(width: BrutalTokens.s2),
                ],
                Flexible(
                  fit: expand ? FlexFit.tight : FlexFit.loose,
                  child: Text(
                    label.toUpperCase(),
                    style: filled > 0.5
                        ? style.copyWith(color: const Color(0xFFFFFFFF))
                        : style,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: BrutalTokens.s2),
                  Text(value!, style: style),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    face = BrutalShadowBox(
      pressed: state.pressed || selected,
      offset: t.shadowOffset,
      color: t.shadow,
      child: face,
    );
    if (!t.padMarkers) return face;
    // The `<-` marker sits outside the right edge on pad devices.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        face,
        if (lit && state.focused)
          Positioned(
            right: -BrutalTokens.s6 - 4,
            top: 0,
            bottom: t.shadowOffset.dy,
            child: Center(
              child: Text('<-', style: t.label.copyWith(color: t.ink)),
            ),
          ),
      ],
    );
  }
}

/// Diagonal stripes alternating danger and black at 45 degrees, 10 px.
class HazardStripes extends StatelessWidget {
  const HazardStripes({super.key});

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return CustomPaint(painter: _StripePainter(t.danger));
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000));
    final p = Paint()
      ..color = color
      ..strokeWidth = 10 / 1.4142
      ..style = PaintingStyle.stroke;
    // Bands 10 px apart measured along the edge, at 45 degrees.
    for (var x = -size.height; x < size.width + size.height; x += 10) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        p,
      );
      x += 10;
    }
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.color != color;
}

/// A hazard button that acts only when held for [duration] (touch, mouse,
/// or A/Enter/Space on a pad or keyboard). The fill grows left to right in
/// danger; letting go early cancels. Replaces "are you sure" dialogs.
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({
    super.key,
    required this.onConfirmed,
    this.label = 'HOLD TO DELETE',
    this.icon,
    this.duration = const Duration(seconds: 1),
    this.expand = false,
    this.focusNode,
    this.autofocus = false,
  });

  final VoidCallback? onConfirmed;
  final String label;
  final IconData? icon;
  final Duration duration;
  final bool expand;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..addStatusListener(_status);
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _focused = false, _hovered = false;

  static final _keys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  bool get _enabled => widget.onConfirmed != null;

  void _status(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      _hold.value = 0;
      widget.onConfirmed?.call();
    }
  }

  void _start() {
    if (_enabled && !_hold.isAnimating) _hold.forward(from: 0);
  }

  // Letting go early cancels at once (no easing back).
  void _cancel() {
    if (_hold.isAnimating || _hold.value > 0) {
      _hold.stop();
      _hold.value = 0;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_keys.contains(e.logicalKey)) return KeyEventResult.ignored;
    if (e is KeyDownEvent) _start();
    if (e is KeyUpEvent) _cancel();
    return KeyEventResult.handled;
  }

  @override
  void didUpdateWidget(HoldToConfirm old) {
    super.didUpdateWidget(old);
    _hold.duration = widget.duration;
  }

  @override
  void dispose() {
    _hold.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      onTap: null,
      child: Focus(
        focusNode: _focus,
        autofocus: widget.autofocus,
        canRequestFocus: _enabled,
        onKeyEvent: _onKey,
        onFocusChange: (_) => setState(() {
          if (!_focus.hasFocus) _cancel();
        }),
        child: Builder(
          builder: (context) {
            _focused =
                _focus.hasFocus &&
                FocusManager.instance.highlightMode ==
                    FocusHighlightMode.traditional;
            return MouseRegion(
              cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: Listener(
                onPointerDown: (_) => _start(),
                onPointerUp: (_) => _cancel(),
                onPointerCancel: (_) => _cancel(),
                child: AnimatedBuilder(
                  animation: _hold,
                  builder: (context, _) => BrutalButtonFace(
                    tokens: t,
                    state: BrutalPressState(
                      pressed: _hold.isAnimating,
                      focused: _focused,
                      hovered: _hovered && _enabled,
                      enabled: _enabled,
                    ),
                    label: widget.label,
                    icon: widget.icon,
                    variant: BrutalButtonVariant.hazard,
                    expand: widget.expand,
                    progress: _hold.value,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The Brutalist look for stock Material buttons (FilledButton,
/// OutlinedButton, ElevatedButton, TextButton), so unconverted screens read
/// Brutalist: square, 3 px ink border, hard shadow that disappears when
/// pressed, yellow when focused or hovered. [flat] drops border and shadow
/// (TextButton).
ButtonStyle brutalButtonStyle(
  BrutalTokens t, {
  BrutalButtonVariant variant = BrutalButtonVariant.plain,
  bool flat = false,
}) {
  final (fill, text) = brutalVariantColors(t, variant);
  bool lit(Set<WidgetState> s) =>
      s.contains(WidgetState.focused) || s.contains(WidgetState.hovered);
  return ButtonStyle(
    textStyle: WidgetStatePropertyAll(t.label),
    backgroundColor: WidgetStateProperty.resolveWith((s) {
      if (s.contains(WidgetState.disabled)) {
        return flat ? Colors.transparent : t.muted;
      }
      if (lit(s)) return t.focus;
      if (s.contains(WidgetState.selected)) return t.focus;
      return flat ? Colors.transparent : fill;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((s) {
      if (s.contains(WidgetState.disabled)) return t.mutedText;
      if (lit(s) || s.contains(WidgetState.selected)) return t.onFocus;
      return flat ? t.ink : text;
    }),
    iconColor: WidgetStateProperty.resolveWith((s) {
      if (s.contains(WidgetState.disabled)) return t.mutedText;
      if (lit(s) || s.contains(WidgetState.selected)) return t.onFocus;
      return flat ? t.ink : text;
    }),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(0),
    splashFactory: NoSplash.splashFactory,
    animationDuration: Duration.zero,
    iconSize: const WidgetStatePropertyAll(BrutalTokens.iconSize),
    minimumSize: WidgetStatePropertyAll(
      Size(flat ? 40 : 64, flat ? t.buttonHeight - 6 : t.buttonHeight),
    ),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: BrutalTokens.s4),
    ),
    shape: WidgetStateProperty.resolveWith((s) {
      if (flat) {
        return BrutalBorder(
          side: lit(s)
              ? BorderSide(color: t.ink, width: BrutalTokens.borderThin)
              : BorderSide.none,
        );
      }
      final pressed = s.contains(WidgetState.pressed);
      final disabled = s.contains(WidgetState.disabled);
      return BrutalBorder(
        side: BorderSide(
          color: lit(s) && fill == t.focus ? t.primary : t.ink,
          width: BrutalTokens.border,
        ),
        shadowOffset: pressed || disabled ? Offset.zero : t.shadowOffset,
        shadowColor: t.shadow,
      );
    }),
    // Room for the shadow outside the button.
    tapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
  );
}

/// The Brutalist look for stock [IconButton]s: square, no border at rest,
/// yellow with an ink border when focused or hovered, ink when selected.
ButtonStyle brutalIconButtonStyle(BrutalTokens t) {
  bool lit(Set<WidgetState> s) =>
      s.contains(WidgetState.focused) || s.contains(WidgetState.hovered);
  return ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((s) {
      if (lit(s)) return t.focus;
      if (s.contains(WidgetState.selected)) return t.ink;
      return Colors.transparent;
    }),
    foregroundColor: WidgetStateProperty.resolveWith((s) {
      if (s.contains(WidgetState.disabled)) return t.mutedText;
      if (lit(s)) return t.onFocus;
      if (s.contains(WidgetState.selected)) return t.panel;
      return t.ink;
    }),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    splashFactory: NoSplash.splashFactory,
    animationDuration: Duration.zero,
    iconSize: const WidgetStatePropertyAll(BrutalTokens.iconSize),
    shape: WidgetStateProperty.resolveWith(
      (s) => BrutalBorder(
        side: lit(s)
            ? BorderSide(color: t.ink, width: BrutalTokens.borderThin)
            : BorderSide.none,
      ),
    ),
  );
}
