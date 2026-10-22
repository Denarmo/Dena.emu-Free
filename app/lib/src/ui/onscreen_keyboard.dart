// SPDX-License-Identifier: GPL-3.0-or-later
// Text entry with the D-pad on handhelds, which have no keyboard.
// Spec: docs/specs/handheld-ui.md (On-screen keyboard)
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/handheld.dart';
import 'brutal/brutal.dart';

/// Opens a full-screen keyboard and returns the text, or null when the user
/// goes back. [accept] decides when Done is allowed; [hint] says why not.
Future<String?> showOnScreenKeyboard(
  BuildContext context, {
  required String title,
  String initial = '',
  bool obscure = false,
  bool Function(String text)? accept,
  String? hint,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute<String>(
    builder: (_) => OnScreenKeyboard(
      title: title,
      initial: initial,
      obscure: obscure,
      accept: accept,
      hint: hint,
    ),
  ),
);

enum _Layer { lower, upper, symbols }

const _letters = ['1234567890', 'qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
const _symbols = ['1234567890', '!@#\$%^&*()', '-_=+[]{};:', '\'",.<>/?\\|`~'];

class OnScreenKeyboard extends StatefulWidget {
  const OnScreenKeyboard({
    super.key,
    required this.title,
    this.initial = '',
    this.obscure = false,
    this.accept,
    this.hint,
  });

  final String title;
  final String initial;
  final bool obscure;
  final bool Function(String text)? accept;
  final String? hint;

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  late String text = widget.initial;
  late bool hidden = widget.obscure;
  _Layer layer = _Layer.lower;

  bool get _ok => widget.accept?.call(text) ?? text.isNotEmpty;

  void _type(String c) => setState(() {
    text += c;
    // Shift is for one letter, like a phone keyboard.
    if (layer == _Layer.upper) layer = _Layer.lower;
  });

  void _backspace() {
    if (text.isEmpty) return;
    setState(
      () => text = String.fromCharCodes(text.runes.toList()..removeLast()),
    );
  }

  void _shift() => setState(
    () => layer = layer == _Layer.lower ? _Layer.upper : _Layer.lower,
  );

  void _symbolsToggle() => setState(
    () => layer = layer == _Layer.symbols ? _Layer.lower : _Layer.symbols,
  );

  void _done() {
    if (_ok) Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final handheld = t.density == BrutalDensity.handheld;
    final rows = layer == _Layer.symbols ? _symbols : _letters;
    final shown = hidden ? '•' * text.runes.length : text;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.gameButtonX): _backspace,
        const SingleActivator(LogicalKeyboardKey.gameButtonY): () => _type(' '),
        const SingleActivator(LogicalKeyboardKey.gameButtonLeft1): _shift,
        const SingleActivator(LogicalKeyboardKey.gameButtonRight1):
            _symbolsToggle,
        const SingleActivator(LogicalKeyboardKey.gameButtonStart): _done,
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            if (widget.obscure)
              Padding(
                padding: const EdgeInsets.only(right: BrutalTokens.s2),
                child: Center(
                  child: BrutalButton(
                    label: hidden ? 'Show' : 'Hide',
                    onPressed: () => setState(() => hidden = !hidden),
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: usesButtons(context)
            ? const BrutalHintBar(
                hints: [
                  ([HintButton.x], 'Del'),
                  ([HintButton.y], 'Space'),
                  ([HintButton.l1], 'Shift'),
                  ([HintButton.r1], '?123'),
                  ([HintButton.start], 'Done'),
                ],
              )
            : null,
        body: BrutalGridPaper(
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(
                handheld ? BrutalTokens.s2 : BrutalTokens.s3,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Field(text: shown),
                  if (widget.hint case final hint? when !_ok)
                    Padding(
                      padding: const EdgeInsets.only(top: BrutalTokens.s1),
                      child: Text(
                        hint,
                        style: t.small.copyWith(color: t.danger),
                      ),
                    ),
                  const SizedBox(height: BrutalTokens.s2),
                  Expanded(
                    child: FocusTraversalGroup(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          for (final (r, row) in rows.indexed)
                            _row(handheld, [
                              for (final (i, c) in row.split('').indexed)
                                _Key(
                                  label: layer == _Layer.upper
                                      ? c.toUpperCase()
                                      : c,
                                  autofocus: r == 1 && i == 0,
                                  onPressed: () => _type(
                                    layer == _Layer.upper ? c.toUpperCase() : c,
                                  ),
                                ),
                            ]),
                          _row(handheld, [
                            _Key(
                              label: 'SHIFT',
                              semanticLabel: 'Shift',
                              selected: layer == _Layer.upper,
                              flex: 2,
                              onPressed: _shift,
                            ),
                            _Key(
                              label: layer == _Layer.symbols ? 'ABC' : '?123',
                              flex: 2,
                              onPressed: _symbolsToggle,
                            ),
                            _Key(
                              label: 'SPACE',
                              semanticLabel: 'Space',
                              flex: 3,
                              onPressed: () => _type(' '),
                            ),
                            _Key(
                              label: 'DEL',
                              semanticLabel: 'Delete',
                              flex: 2,
                              onPressed: _backspace,
                            ),
                            _Key(
                              label: 'OK',
                              semanticLabel: 'Done',
                              flex: 2,
                              primary: true,
                              onPressed: _ok ? _done : null,
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A row of keys: 40 px square-ish keys on the handheld, filling the
  /// height elsewhere.
  Widget _row(bool handheld, List<Widget> keys) {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: keys,
    );
    return handheld
        ? SizedBox(height: 40 + BrutalTokens.s1 + 3, child: row)
        : Expanded(child: row);
  }
}

/// The typed text in a read-only command box: `>` prompt, mono text and a
/// block cursor (brutalist-ui.md 4.9).
class _Field extends StatelessWidget {
  const _Field({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s3,
        vertical: BrutalTokens.s2,
      ),
      child: Row(
        children: [
          Text('> ', style: t.title.copyWith(color: t.mutedText)),
          Flexible(
            child: Text(
              text.isEmpty ? ' ' : text,
              key: const ValueKey('osk-text'),
              style: t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ExcludeSemantics(child: Text('█', style: t.title)),
        ],
      ),
    );
  }
}

/// One key: a hard rectangle on a shadow, yellow when focused, blue for
/// Done and a held Shift.
class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.flex = 1,
    this.autofocus = false,
    this.selected = false,
    this.primary = false,
  });

  final String label;
  final String? semanticLabel;
  final VoidCallback? onPressed;
  final int flex;
  final bool autofocus;
  final bool selected;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(BrutalTokens.s1 / 2),
        child: BrutalPressable(
          onPressed: onPressed,
          autofocus: autofocus,
          selected: selected,
          semanticLabel: semanticLabel ?? label,
          builder: (context, s) {
            final (fill, fg) = !s.enabled
                ? (t.muted, t.mutedText)
                : s.highlighted
                ? (t.focus, t.onFocus)
                : primary || selected
                ? (t.primary, t.onPrimary)
                : (t.panel, t.ink);
            return BrutalShadowBox(
              pressed: s.pressed || selected,
              offset: t.shadowOffset,
              color: t.shadow,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: fill,
                  border: Border.all(
                    color: t.ink,
                    width: BrutalTokens.borderThin,
                  ),
                ),
                child: ExcludeSemantics(
                  child: Text(
                    label,
                    style: (label.length > 1 ? t.label : t.title).copyWith(
                      color: fg,
                    ),
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

/// On handhelds, A on a focused text field opens the on-screen keyboard with
/// its text and writes the result back, so every field in the app (cheats,
/// sign-ins, servers, searches) can be typed in (handheld-ui.md). Wrap the
/// app's routes with this.
class HandheldTextEntry extends StatelessWidget {
  const HandheldTextEntry({
    super.key,
    this.enabled = true,
    required this.child,
  });

  /// Off: keys pass through (the widget stays, so the routes below keep
  /// their state when controller mode turns on or off).
  final bool enabled;
  final Widget child;

  /// Another keyboard for fields, tried first: Steam's in Gaming Mode
  /// (deck-presets.md). It returns false when it could not open, and the
  /// on-screen keyboard opens instead.
  static Future<bool> Function(EditableText field)? external;

  static KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.gameButtonA) {
      return KeyEventResult.ignored;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return KeyEventResult.ignored;
    final field = context.widget is EditableText
        ? context.widget as EditableText
        : context.findAncestorWidgetOfExactType<EditableText>();
    if (field == null || field.readOnly) return KeyEventResult.ignored;
    final decoration = context
        .findAncestorWidgetOfExactType<TextField>()
        ?.decoration;
    final title = decoration?.labelText ?? decoration?.hintText ?? 'Type';
    final other = external;
    if (other == null) {
      _type(context, field, title);
    } else {
      other(field).then((opened) {
        if (!opened && context.mounted) _type(context, field, title);
      });
    }
    return KeyEventResult.handled;
  }

  static Future<void> _type(
    BuildContext context,
    EditableText field,
    String title,
  ) async {
    final text = await showOnScreenKeyboard(
      context,
      title: title,
      initial: field.controller.text,
      obscure: field.obscureText,
      accept: (_) => true,
    );
    if (text == null) return;
    field.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    field.onChanged?.call(text);
    // Search and submit fields act on Done, as they would on Enter.
    if (const {
      TextInputAction.search,
      TextInputAction.done,
      TextInputAction.go,
      TextInputAction.send,
    }.contains(field.textInputAction)) {
      field.onSubmitted?.call(text);
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: enabled ? _onKey : null,
    child: child,
  );
}
