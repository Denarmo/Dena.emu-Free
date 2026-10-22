// SPDX-License-Identifier: GPL-3.0-or-later
// Brutalist pieces shared by the music and video players: the screen frame,
// square icon keys, the seek bar, art cells and messages. Composed from the
// kit in ui/brutal/; nothing here belongs in the kit yet.
// Spec: docs/specs/media-players.md, brutalist-ui.md (4.8)
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// L1 / R1 shortcuts for switching categories.
Map<ShortcutActivator, VoidCallback> categoryKeys(
  int count,
  int selected,
  ValueChanged<int> onSelected,
) => {
  const SingleActivator(LogicalKeyboardKey.gameButtonLeft1): () =>
      onSelected((selected - 1 + count) % count),
  const SingleActivator(LogicalKeyboardKey.gameButtonRight1): () =>
      onSelected((selected + 1) % count),
};

/// A media screen: grid paper, a header row with a back key, the title
/// (`MUSIC/`), the path (`/apps > music`) and [actions], then [child].
class MediaScaffold extends StatelessWidget {
  const MediaScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.autofocusBack = false,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  /// Focus the back key first (the body has nothing focusable).
  final bool autofocusBack;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final pad = t.density == BrutalDensity.handheld
        ? BrutalTokens.s2
        : BrutalTokens.s3;
    return Scaffold(
      backgroundColor: t.ground,
      body: BrutalGridPaper(
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    MediaKey(
                      // Remounted when it starts to want focus, since
                      // autofocus only acts on a new widget.
                      key: ValueKey('back-$autofocusBack'),
                      icon: DenaIcons.arrowBack,
                      tooltip: 'Back',
                      autofocus: autofocusBack,
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: BrutalTokens.s2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${title.toUpperCase()}/',
                            style: t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          PathBar(segments: ['apps', title.toLowerCase()]),
                        ],
                      ),
                    ),
                    for (final a in actions) ...[
                      const SizedBox(width: BrutalTokens.s2),
                      a,
                    ],
                  ],
                ),
                const SizedBox(height: BrutalTokens.s2),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A square key with one Dena icon on a hard shadow: the transport buttons.
/// [primary] is blue (play); [active] is ink-filled like `[ON]` (shuffle,
/// repeat). Focused or hovered it turns yellow.
class MediaKey extends StatelessWidget {
  const MediaKey({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
    this.active = false,
    this.autofocus = false,
    this.size,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool primary;
  final bool active;
  final bool autofocus;

  /// The face's side; null is the density's button height.
  final double? size;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final side = size ?? t.buttonHeight;
    return Tooltip(
      message: tooltip,
      child: BrutalPressable(
        onPressed: onPressed,
        autofocus: autofocus,
        focusNode: focusNode,
        selected: active,
        builder: (context, s) {
          var (fill, fg) = primary
              ? (t.primary, t.onPrimary)
              : active
              ? (t.ink, t.panel)
              : (t.panel, t.ink);
          if (s.highlighted) (fill, fg) = (t.focus, t.onFocus);
          if (!s.enabled) (fill, fg) = (t.muted, t.mutedText);
          return BrutalShadowBox(
            pressed: s.pressed,
            offset: t.shadowOffset,
            color: t.shadow,
            child: Container(
              width: side,
              height: side,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                border: Border.all(color: t.ink, width: BrutalTokens.border),
              ),
              child: Icon(
                icon,
                color: fg,
                size: side >= 54
                    ? BrutalTokens.iconSizeLarge
                    : BrutalTokens.iconSize,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// How far one press of left / right moves a [MediaSeekBar]: 1/20 of the
/// length, as a 20-step `BracketSlider`.
const int mediaSeekSteps = 20;

/// The seek bar: elapsed time, a hard bar (ink fill for the played part)
/// and the total, in mono. Tap or drag seeks on touch; left / right on a
/// pad or keyboard step by 1/[mediaSeekSteps] of the length. Focused it
/// turns yellow.
class MediaSeekBar extends StatefulWidget {
  const MediaSeekBar({
    super.key,
    required this.positionMs,
    required this.durationMs,
    required this.onSeek,
    required this.format,
    this.focusNode,
  });

  final int positionMs;
  final int durationMs;
  final ValueChanged<int> onSeek;
  final String Function(int ms) format;
  final FocusNode? focusNode;

  @override
  State<MediaSeekBar> createState() => _MediaSeekBarState();
}

class _SeekIntent extends Intent {
  const _SeekIntent(this.steps);

  final int steps;
}

class _MediaSeekBarState extends State<MediaSeekBar> {
  /// The dragged-to fraction while a drag is under way.
  double? _drag;

  /// The last position asked for by a key, until the player catches up, so
  /// held keys keep stepping from where they were.
  int? _keyed;

  int get _total => widget.durationMs;

  @override
  void didUpdateWidget(MediaSeekBar old) {
    super.didUpdateWidget(old);
    if (widget.positionMs != old.positionMs) _keyed = null;
  }

  void _step(int steps) {
    if (_total <= 0) return;
    final from = _keyed ?? widget.positionMs;
    final to = (from + steps * _total / mediaSeekSteps).round().clamp(
      0,
      _total,
    );
    setState(() => _keyed = to);
    widget.onSeek(to);
  }

  double _fractionAt(Offset p, double width) =>
      width <= 0 ? 0 : (p.dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final enabled = _total > 0;
    final shownMs = _drag != null
        ? (_drag! * _total).round()
        : (_keyed ?? widget.positionMs).clamp(0, enabled ? _total : 0);
    final fraction = enabled ? shownMs / _total : 0.0;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      enabled: enabled,
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _SeekIntent(1),
      },
      actions: {
        _SeekIntent: CallbackAction<_SeekIntent>(
          onInvoke: (i) => _step(i.steps),
        ),
      },
      child: Builder(
        builder: (context) {
          final focused =
              Focus.of(context).hasFocus &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional;
          final ink = focused ? t.onFocus : t.ink;
          final times = t.small.copyWith(
            color: focused ? t.onFocus : t.ink,
            fontWeight: FontWeight.w600,
          );
          return Semantics(
            slider: true,
            label: 'Seek',
            value: widget.format(shownMs),
            increasedValue: widget.format(
              (shownMs + _total ~/ mediaSeekSteps).clamp(0, _total),
            ),
            decreasedValue: widget.format(
              (shownMs - _total ~/ mediaSeekSteps).clamp(0, _total),
            ),
            onIncrease: enabled ? () => _step(1) : null,
            onDecrease: enabled ? () => _step(-1) : null,
            child: Container(
              color: focused ? t.focus : null,
              padding: const EdgeInsets.symmetric(
                horizontal: BrutalTokens.s1,
                vertical: BrutalTokens.s1,
              ),
              child: Row(
                children: [
                  Text(widget.format(shownMs), style: times),
                  const SizedBox(width: BrutalTokens.s2),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: enabled
                            ? (d) => widget.onSeek(
                                (_fractionAt(d.localPosition, box.maxWidth) *
                                        _total)
                                    .round(),
                              )
                            : null,
                        onHorizontalDragStart: enabled
                            ? (d) => setState(
                                () => _drag = _fractionAt(
                                  d.localPosition,
                                  box.maxWidth,
                                ),
                              )
                            : null,
                        onHorizontalDragUpdate: enabled
                            ? (d) => setState(
                                () => _drag = _fractionAt(
                                  d.localPosition,
                                  box.maxWidth,
                                ),
                              )
                            : null,
                        onHorizontalDragEnd: enabled
                            ? (_) {
                                final f = _drag;
                                setState(() => _drag = null);
                                if (f != null) {
                                  widget.onSeek((f * _total).round());
                                }
                              }
                            : null,
                        onHorizontalDragCancel: () =>
                            setState(() => _drag = null),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: ProgressCell(
                            value: fraction,
                            showPercent: false,
                            width: box.maxWidth,
                            height: 14,
                            color: ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: BrutalTokens.s2),
                  Text(widget.format(_total), style: times),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Art in a hard black frame: [bytes] when there are any, else a muted box
/// with [icon].
class MediaArt extends StatelessWidget {
  const MediaArt({
    super.key,
    required this.bytes,
    required this.icon,
    required this.width,
    required this.height,
    this.shadow = false,
  });

  final Uint8List? bytes;
  final IconData icon;
  final double width;
  final double height;

  /// A hard shadow (the large now-playing art).
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final iconSize = height >= 81
        ? BrutalTokens.iconSizeLarge * 2
        : height >= 36
        ? BrutalTokens.iconSize
        : 9.0;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: t.muted,
        border: Border.all(
          color: const Color(0xFF000000),
          width: BrutalTokens.borderThin,
        ),
        boxShadow: shadow
            ? [BoxShadow(color: t.shadow, offset: t.shadowOffsetLarge)]
            : null,
      ),
      clipBehavior: Clip.hardEdge,
      child: bytes != null
          ? Image.memory(bytes!, fit: BoxFit.cover, gaplessPlayback: true)
          : Center(
              child: Icon(icon, size: iconSize, color: t.mutedText),
            ),
    );
  }
}

/// [MediaArt] from a thumbnail future.
class MediaThumb extends StatelessWidget {
  const MediaThumb({
    super.key,
    required this.future,
    required this.icon,
    required this.width,
    required this.height,
    this.shadow = false,
  });

  final Future<Uint8List?> future;
  final IconData icon;
  final double width;
  final double height;
  final bool shadow;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (_, snap) => MediaArt(
      bytes: snap.data,
      icon: icon,
      width: width,
      height: height,
      shadow: shadow,
    ),
  );
}

/// Permission refused / nothing found: an [EmptyState] at the top left.
class MediaMessage extends StatelessWidget {
  const MediaMessage({
    super.key,
    required this.headline,
    required this.text,
    this.action,
    this.onAction,
  });

  final String headline;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: SingleChildScrollView(
      child: EmptyState(
        headline: headline,
        message: text,
        action: action,
        onAction: onAction,
        icon: action == null ? null : DenaIcons.lock,
        autofocus: true,
      ),
    ),
  );
}

/// The loading line: `> scanning music ...`.
class MediaLoading extends StatelessWidget {
  const MediaLoading(this.what, {super.key});

  final String what;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(BrutalTokens.s4),
    child: LogLine('scanning $what ...'),
  );
}
