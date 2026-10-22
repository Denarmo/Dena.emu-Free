// SPDX-License-Identifier: GPL-3.0-or-later
// Brutalist overlays and hints: key glyphs, the hint bar, dialogs, sheets
// and toasts.
// Spec: docs/specs/brutalist-ui.md (3)
import 'package:material_ui/material_ui.dart';

import '../../desktop/controller_mode.dart' show ControllerScope;
import '../../shell/handheld.dart' show ButtonHint, HintButton;
import '../../shell/platform_features.dart';
import 'button.dart';
import 'surfaces.dart';
import 'tokens.dart';

/// A button hint glyph: a bracketed key drawn as a 22 px bordered square
/// with the pad's own letter or shape (controller-mode.md, Glyphs). The
/// confirm button (A) is filled yellow.
class KeyGlyph extends StatelessWidget {
  const KeyGlyph(this.button, {super.key});

  final HintButton button;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final label = button.glyphFor(ControllerScope.familyOf(context));
    final confirm = button == HintButton.a;
    return Container(
      height: 22,
      constraints: const BoxConstraints(minWidth: 22),
      padding: EdgeInsets.symmetric(horizontal: label.length > 1 ? 4 : 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: confirm ? t.focus : t.panel,
        border: Border.all(color: t.ink, width: BrutalTokens.borderThin),
      ),
      child: Text(
        label,
        style: t.small.copyWith(
          fontWeight: FontWeight.w700,
          color: confirm ? t.onFocus : t.ink,
          height: 1,
        ),
      ),
    );
  }
}

/// The bottom bar of [KeyGlyph] + label pairs (`[A] OK  [B] BACK`), 30 px.
/// The hint logic stays with the screens (handheld-ui.md).
class BrutalHintBar extends StatelessWidget {
  const BrutalHintBar({super.key, required this.hints});

  final List<ButtonHint> hints;

  static const height = 30.0;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(
          top: BorderSide(color: t.ink, width: BrutalTokens.border),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: BrutalTokens.s3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (final (i, (buttons, label)) in hints.indexed) ...[
            if (i > 0) const SizedBox(width: BrutalTokens.s4),
            for (final b in buttons) ...[
              KeyGlyph(b),
              const SizedBox(width: 2),
            ],
            const SizedBox(width: BrutalTokens.s1),
            Text(label.toUpperCase(), style: t.label),
          ],
        ],
      ),
    );
  }
}

/// A panel with a header-strip [title] (`DELETE?`, `SIGN IN`), a [body] and
/// right-aligned [actions], on a 6 px shadow.
class BrutalDialog extends StatelessWidget {
  const BrutalDialog({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.maxWidth = 440,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(BrutalTokens.s4),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Material(
            type: MaterialType.transparency,
            child: BrutalPanel(
              header: title,
              large: true,
              padding: const EdgeInsets.all(BrutalTokens.s4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Flexible(
                    child: SingleChildScrollView(
                      child: DefaultTextStyle.merge(
                        style: t.body,
                        child: body,
                      ),
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: BrutalTokens.s4),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: BrutalTokens.s2,
                      runSpacing: BrutalTokens.s2,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [builder]'s widget (usually a [BrutalDialog]) at once over a black
/// 40 % scrim; no transition.
Future<T?> showBrutalDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: BrutalTokens.scrim,
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => builder(context),
);

/// Where a [BrutalSheet] sits: the bottom on phones, a right-hand side
/// panel on handhelds and desktops.
enum BrutalSheetSide { bottom, right }

/// A sheet: a full-width panel with a top border on phones, a side panel
/// with a left border elsewhere. Optional header strip [title].
class BrutalSheet extends StatelessWidget {
  const BrutalSheet({
    super.key,
    required this.child,
    this.title,
    this.side,
    this.width = 300,
  });

  final Widget child;
  final String? title;

  /// Null picks by density (bottom on phones).
  final BrutalSheetSide? side;

  /// The side panel's width.
  final double width;

  static BrutalSheetSide sideFor(BuildContext context) =>
      BrutalTokens.of(context).density == BrutalDensity.phone
      ? BrutalSheetSide.bottom
      : BrutalSheetSide.right;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final s = side ?? sideFor(context);
    final edge = BorderSide(color: t.ink, width: BrutalTokens.border);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) BrutalHeaderStrip(title!),
        Flexible(child: child),
      ],
    );
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: s == BrutalSheetSide.right ? width : double.infinity,
        decoration: BoxDecoration(
          color: t.panel,
          border: s == BrutalSheetSide.bottom
              ? Border(top: edge)
              : Border(left: edge),
        ),
        child: SafeArea(
          top: s == BrutalSheetSide.right,
          left: false,
          child: content,
        ),
      ),
    );
  }
}

/// Shows a [BrutalSheet] built by [builder] at once over the scrim, at the
/// bottom on phones and on the right elsewhere.
Future<T?> showBrutalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final side = BrutalSheet.sideFor(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: BrutalTokens.scrim,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => Align(
      alignment: side == BrutalSheetSide.bottom
          ? Alignment.bottomCenter
          : Alignment.centerRight,
      child: side == BrutalSheetSide.bottom
          ? builder(context)
          : SizedBox(height: double.infinity, child: builder(context)),
    ),
  );
}

/// The prefix of a toast.
enum ToastKind { ok, err, info }

/// A Brutalist toast: `OK > screenshot saved` on a black bar for 3 s. The
/// snackbar theme already draws every SnackBar this way; this adds the
/// prefix.
SnackBar brutalToast(String message, {ToastKind kind = ToastKind.ok}) =>
    SnackBar(
      content: Text(switch (kind) {
        ToastKind.ok => 'OK > $message',
        ToastKind.err => 'ERR > $message',
        ToastKind.info => '> $message',
      }),
      duration: const Duration(seconds: 3),
    );

/// The snackbar theme behind [brutalToast]: black bar, white mono text,
/// square, top-right on desktop (as far as SnackBar allows: floating with
/// a narrow width), bottom elsewhere.
SnackBarThemeData brutalSnackBarTheme(BrutalTokens t) {
  final desktop = shellProfile == ShellProfile.desktop;
  return SnackBarThemeData(
    backgroundColor: const Color(0xFF000000),
    contentTextStyle: t.body.copyWith(color: const Color(0xFFFFFFFF)),
    actionTextColor: t.focus,
    behavior: SnackBarBehavior.floating,
    width: desktop ? 420 : null,
    insetPadding: desktop
        ? null
        : const EdgeInsets.fromLTRB(
            BrutalTokens.s3,
            BrutalTokens.s1,
            BrutalTokens.s3,
            BrutalTokens.s3,
          ),
    elevation: 0,
    // Square; the border shows only on Ink, where the bar meets black.
    shape: BeveledRectangleBorder(
      side: BorderSide(color: t.ink, width: BrutalTokens.borderThin),
    ),
  );
}

/// A plain dialog action: the [BrutalButton] the dialog's buttons use.
class BrutalDialogAction extends StatelessWidget {
  const BrutalDialogAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => BrutalButton(
    label: label,
    onPressed: onPressed,
    autofocus: autofocus,
    variant: primary ? BrutalButtonVariant.primary : BrutalButtonVariant.plain,
  );
}
