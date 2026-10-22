// SPDX-License-Identifier: GPL-3.0-or-later
// Brutalist controls: tabs, filters, the command field, the path bar and the
// config widgets (bracket slider, ON/OFF key, segment, config table).
// Spec: docs/specs/brutalist-ui.md (3)
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'pressable.dart';
import 'surfaces.dart';
import 'tokens.dart';

/// One tab of a [BrutalTabBar].
@immutable
class BrutalTabItem {
  const BrutalTabItem({required this.label, this.icon});

  final String label;
  final IconData? icon;
}

/// A pressable tab: icon above the label ([vertical], phone) or left of it
/// (rail, header). The selected tab is yellow and drawn pressed.
class BrutalTab extends StatelessWidget {
  const BrutalTab({
    super.key,
    required this.item,
    required this.selected,
    required this.onPressed,
    this.vertical = true,
    this.focusNode,
  });

  final BrutalTabItem item;
  final bool selected;
  final VoidCallback? onPressed;
  final bool vertical;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPressable(
      onPressed: onPressed,
      focusNode: focusNode,
      selected: selected,
      semanticLabel: item.label,
      builder: (context, s) {
        final yellow = selected || s.highlighted;
        final fg = yellow ? t.onFocus : t.ink;
        final label = Text(
          item.label.toUpperCase(),
          style: t.label.copyWith(color: fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
        final icon = item.icon == null
            ? null
            : Icon(
                item.icon,
                color: fg,
                size: vertical
                    ? BrutalTokens.iconSizeLarge
                    : BrutalTokens.iconSize,
              );
        final content = vertical
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?icon,
                  if (icon != null) const SizedBox(height: 2),
                  // Four phone tabs leave ~70 dp per label: shrink a long
                  // one (SETTINGS) instead of cutting it off.
                  FittedBox(fit: BoxFit.scaleDown, child: label),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?icon,
                  if (icon != null) const SizedBox(width: BrutalTokens.s2),
                  Flexible(child: label),
                ],
              );
        return BrutalShadowBox(
          pressed: selected || s.pressed,
          offset: t.shadowOffset,
          color: t.shadow,
          child: Container(
            alignment: vertical ? Alignment.center : Alignment.centerLeft,
            constraints: BoxConstraints(minHeight: t.buttonHeight),
            padding: const EdgeInsets.symmetric(
              horizontal: BrutalTokens.s2,
              vertical: BrutalTokens.s1,
            ),
            decoration: BoxDecoration(
              color: yellow ? t.focus : t.panel,
              border: Border.all(
                color: selected && s.focused ? t.primary : t.ink,
                width: BrutalTokens.border,
              ),
            ),
            child: content,
          ),
        );
      },
    );
  }
}

/// A row ([vertical] false: a column) of [BrutalTab]s. L1/R1 switching is
/// the owner's job (the shell), as today.
class BrutalTabBar extends StatelessWidget {
  const BrutalTabBar({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onSelected,
    this.axis = Axis.horizontal,
    this.iconAbove = true,
  });

  final List<BrutalTabItem> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Horizontal under the wordmark (phone), vertical in the handheld rail.
  final Axis axis;
  final bool iconAbove;

  @override
  Widget build(BuildContext context) {
    final children = [
      for (final (i, tab) in tabs.indexed)
        BrutalTab(
          item: tab,
          selected: i == selected,
          vertical: iconAbove,
          onPressed: () => onSelected(i),
        ),
    ];
    return FocusTraversalGroup(
      child: axis == Axis.horizontal
          ? Row(
              children: [
                for (final (i, c) in children.indexed) ...[
                  if (i > 0) const SizedBox(width: BrutalTokens.s1),
                  Expanded(child: c),
                ],
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, c) in children.indexed) ...[
                  if (i > 0) const SizedBox(height: BrutalTokens.s1),
                  c,
                ],
              ],
            ),
    );
  }
}

/// A text toggle: `[x]ALL(12)` / `[ ]NES(2)`; the checked one is yellow.
class CheckFilter extends StatelessWidget {
  const CheckFilter({
    super.key,
    required this.label,
    required this.checked,
    required this.onPressed,
    this.count,
    this.focusNode,
    this.autofocus = false,
  });

  final String label;
  final bool checked;
  final int? count;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool autofocus;

  /// The text shown, e.g. `[x]ALL(12)`.
  String get text =>
      '[${checked ? 'x' : ' '}]${label.toUpperCase()}'
      '${count == null ? '' : '($count)'}';

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPressable(
      onPressed: onPressed,
      focusNode: focusNode,
      autofocus: autofocus,
      selected: checked,
      semanticLabel: label,
      builder: (context, s) {
        final yellow = checked || s.highlighted;
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: BrutalTokens.s1 + 2,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: yellow ? t.focus : null,
            border: Border.all(
              color: checked && s.focused
                  ? t.primary
                  : (yellow ? t.ink : Colors.transparent),
              width: BrutalTokens.borderThin,
            ),
          ),
          child: Text(
            text,
            style: t.label.copyWith(color: yellow ? t.onFocus : t.ink),
          ),
        );
      },
    );
  }
}

/// The search / text input: a bordered panel with a `>` prompt, mono text,
/// a block cursor `█` that blinks in 500 ms steps (steady when animations
/// are off) and a leading search icon.
class CommandField extends StatefulWidget {
  const CommandField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.icon,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final IconData? icon;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<CommandField> createState() => _CommandFieldState();
}

class _CommandFieldState extends State<CommandField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  Timer? _blink;
  bool _cursorOn = true;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    _controller.addListener(_changed);
  }

  void _changed() => setState(() {});

  void _focusChanged() {
    _blink?.cancel();
    _cursorOn = true;
    if (_focus.hasFocus &&
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _blink = Timer.periodic(BrutalTokens.blink, (_) {
        if (mounted) setState(() => _cursorOn = !_cursorOn);
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _blink?.cancel();
    _focus.removeListener(_focusChanged);
    _controller.removeListener(_changed);
    if (widget.focusNode == null) _focus.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final focused = _focus.hasFocus;
    final empty = _controller.text.isEmpty;
    return Container(
      constraints: BoxConstraints(minHeight: t.buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: BrutalTokens.s2),
      decoration: BoxDecoration(
        color: t.panel,
        border: Border.all(
          color: focused ? t.primary : t.ink,
          width: BrutalTokens.border,
        ),
      ),
      child: Row(
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: BrutalTokens.iconSize, color: t.ink),
            const SizedBox(width: BrutalTokens.s2),
          ],
          Text('>', style: t.row),
          const SizedBox(width: BrutalTokens.s2),
          Expanded(
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                if (empty && widget.hint != null)
                  IgnorePointer(
                    child: Text(
                      widget.hint!,
                      style: t.body.copyWith(color: t.mutedText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                EditableText(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  style: t.body,
                  // The system caret is replaced by the block cursor.
                  cursorColor: Colors.transparent,
                  showCursor: false,
                  backgroundCursorColor: t.muted,
                  selectionColor: t.focus,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          if (focused)
            Opacity(
              opacity: _cursorOn ? 1 : 0,
              child: Text('█', style: t.row),
            ),
        ],
      ),
    );
  }
}

/// The `/games > all` breadcrumb: current tab, filter and sort, with an
/// optional hint on the right (`L/R` on the handheld).
class PathBar extends StatelessWidget {
  const PathBar({super.key, required this.segments, this.hint});

  final List<String> segments;
  final String? hint;

  /// `/games > all > title`.
  String get path => '/${segments.join(' > ')}';

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final style = t.small.copyWith(color: t.ink);
    return Row(
      children: [
        Expanded(
          child: Text(path, style: style, overflow: TextOverflow.ellipsis),
        ),
        if (hint != null)
          Text(hint!, style: style.copyWith(color: t.mutedText)),
      ],
    );
  }
}

/// `[#####-----] 50%`: a stepped slider of [steps] cells. Left/right change
/// it on pads and keyboards; tap or drag on touch.
class BracketSlider extends StatelessWidget {
  const BracketSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.steps = 10,
    this.showPercent = true,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
  });

  /// 0 to 1, shown snapped to the nearest step.
  final double value;
  final ValueChanged<double>? onChanged;
  final int steps;
  final bool showPercent;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;

  int get _filled => (value.clamp(0, 1) * steps).round();

  /// The text shown, e.g. `[#####-----] 50%`.
  String get text {
    final bar = '${'#' * _filled}${'-' * (steps - _filled)}';
    return '[$bar]${showPercent ? ' ${(_filled * 100 / steps).round()}%' : ''}';
  }

  void _set(int cells) {
    final c = cells.clamp(0, steps);
    if (c != _filled) onChanged?.call(c / steps);
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final enabled = onChanged != null;
    return Semantics(
      slider: true,
      label: semanticLabel,
      value: '${(_filled * 100 / steps).round()}%',
      increasedValue:
          '${(((_filled + 1).clamp(0, steps)) * 100 / steps).round()}%',
      decreasedValue:
          '${(((_filled - 1).clamp(0, steps)) * 100 / steps).round()}%',
      onIncrease: enabled ? () => _set(_filled + 1) : null,
      onDecrease: enabled ? () => _set(_filled - 1) : null,
      child: FocusableActionDetector(
        focusNode: focusNode,
        autofocus: autofocus,
        enabled: enabled,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
        },
        actions: {
          _StepIntent: CallbackAction<_StepIntent>(
            onInvoke: (i) => _set(_filled + i.delta),
          ),
        },
        child: Builder(
          builder: (context) {
            final focused =
                Focus.of(context).hasFocus &&
                FocusManager.instance.highlightMode ==
                    FocusHighlightMode.traditional;
            return LayoutBuilder(
              builder: (context, box) {
                void at(Offset p) {
                  final w = box.maxWidth.isFinite ? box.maxWidth : 200;
                  // The cells sit between the brackets; rough is fine.
                  _set((p.dx / w * steps).ceil());
                }

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: enabled ? (d) => at(d.localPosition) : null,
                  onHorizontalDragUpdate: enabled
                      ? (d) => at(d.localPosition)
                      : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BrutalTokens.s1,
                      vertical: 2,
                    ),
                    color: focused ? t.focus : null,
                    child: Text(
                      text,
                      style: t.row.copyWith(
                        color: !enabled
                            ? t.mutedText
                            : (focused ? t.onFocus : t.ink),
                      ),
                      maxLines: 1,
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.delta);

  final int delta;
}

/// `[ON]` / `[OFF]`: a hard two-state key. ON is ink-filled with panel text;
/// OFF is the panel.
class CfgToggle extends StatelessWidget {
  const CfgToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Semantics(
      toggled: value,
      child: BrutalPressable(
        onPressed: onChanged == null ? null : () => onChanged!(!value),
        focusNode: focusNode,
        autofocus: autofocus,
        semanticLabel: semanticLabel,
        builder: (context, s) {
          var fill = value ? t.ink : t.panel;
          var fg = value ? t.panel : t.ink;
          if (s.highlighted) {
            fill = t.focus;
            fg = t.onFocus;
          }
          if (!s.enabled) {
            fill = t.muted;
            fg = t.mutedText;
          }
          return BrutalShadowBox(
            pressed: s.pressed,
            offset: t.shadowOffset,
            color: t.shadow,
            child: Container(
              constraints: const BoxConstraints(minWidth: 58),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(
                horizontal: BrutalTokens.s2,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(
                  color: t.ink,
                  width: BrutalTokens.borderThin,
                ),
              ),
              child: Text(
                value ? '[ON]' : '[OFF]',
                style: t.label.copyWith(color: fg),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// `[1X] 2X 4X`: a bracketed choice; the selected value is in brackets and
/// yellow. Left/right move between values as focus.
class CfgSegment<T> extends StatelessWidget {
  const CfgSegment({
    super.key,
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.labelOf,
  });

  final List<T> values;
  final T selected;
  final ValueChanged<T>? onChanged;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return FocusTraversalGroup(
      child: Wrap(
        spacing: BrutalTokens.s1,
        runSpacing: BrutalTokens.s1,
        children: [
          for (final v in values)
            BrutalPressable(
              onPressed: onChanged == null ? null : () => onChanged!(v),
              selected: v == selected,
              semanticLabel: labelOf(v),
              builder: (context, s) {
                final on = v == selected;
                final yellow = on || s.highlighted;
                final label = labelOf(v).toUpperCase();
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BrutalTokens.s1,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: yellow ? t.focus : null,
                    border: Border.all(
                      color: on && s.focused
                          ? t.primary
                          : (yellow ? t.ink : Colors.transparent),
                      width: BrutalTokens.borderThin,
                    ),
                  ),
                  child: Text(
                    on ? '[$label]' : ' $label ',
                    style: t.label.copyWith(
                      color: !s.enabled
                          ? t.mutedText
                          : (yellow ? t.onFocus : t.ink),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One `KEY ............ VALUE` row of a [CfgTable] with its control on the
/// right. With [onOpen] and no [control] it is a `>` row that opens a page.
class CfgRow extends StatelessWidget {
  const CfgRow({
    super.key,
    required this.label,
    this.control,
    this.value,
    this.onOpen,
    this.autofocus = false,
  });

  final String label;
  final Widget? control;

  /// Text shown before the `>` of an opening row.
  final String? value;
  final VoidCallback? onOpen;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    // The dotted leader runs behind the row; the label and the trailing
    // part sit on the row's fill over it, so a long label or value
    // shortens the dots and then ellipsizes instead of overflowing.
    Widget row(Color fg, Color fill, {required Widget trailing}) => Container(
      constraints: BoxConstraints(minHeight: t.rowHeight),
      padding: const EdgeInsets.symmetric(horizontal: BrutalTokens.s3),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '.' * 200,
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                style: t.small.copyWith(color: fg.withValues(alpha: 0.4)),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: ColoredBox(
                  color: fill,
                  child: Padding(
                    padding: const EdgeInsets.only(right: BrutalTokens.s2),
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.label.copyWith(color: fg),
                    ),
                  ),
                ),
              ),
              trailing,
            ],
          ),
        ],
      ),
    );
    // The trailing part on the fill, left of it a gap where the dots stop.
    Widget onFill(Color fill, Widget child) => ColoredBox(
      color: fill,
      child: Padding(
        padding: const EdgeInsets.only(left: BrutalTokens.s2),
        child: child,
      ),
    );
    if (control != null) {
      return row(t.ink, t.panel, trailing: onFill(t.panel, control!));
    }
    return BrutalPressable(
      onPressed: onOpen,
      autofocus: autofocus,
      semanticLabel: label,
      builder: (context, s) {
        final lit = s.highlighted;
        final fg = lit ? t.onFocus : t.ink;
        final fill = lit ? t.focus : t.panel;
        return ColoredBox(
          color: fill,
          child: row(
            fg,
            fill,
            trailing: Flexible(
              child: onFill(
                fill,
                Text(
                  '${value == null ? '' : '$value '}>',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.label.copyWith(color: fg),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A settings section: a [BrutalPanel] with a header like `VIDEO.CFG` and
/// [CfgRow]s divided by thin rules.
class CfgTable extends StatelessWidget {
  const CfgTable({super.key, required this.header, required this.rows});

  final String header;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPanel(
      header: header,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0)
              Container(height: BrutalTokens.borderThin, color: t.muted),
            r,
          ],
        ],
      ),
    );
  }
}
