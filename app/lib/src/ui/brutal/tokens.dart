// SPDX-License-Identifier: GPL-3.0-or-later
// The Brutalist design tokens: colours, type, space, borders, shadows and
// motion in one place. Widgets read BrutalTokens.of(context); nothing else
// hard-codes these numbers.
// Spec: docs/specs/brutalist-ui.md (2. Design tokens)
import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

import '../../shell/handheld.dart' show Handheld;
import '../../shell/platform_features.dart';

/// The functional face: tables, labels, buttons, paths, logs, settings.
const String brutalMono = 'IBM Plex Mono';

/// The display face, UPPERCASE only: wordmark, PLAY, PAUSED, empty states.
const String brutalDisplay = 'Archivo Black';

/// Faces tried after [brutalMono] for glyphs it lacks.
const List<String> brutalFallback = ['Roboto'];

/// Hazard yellow: focus and selection. Text on it is always black.
const Color brutalHazard = Color(0xFFFFE600);

/// The Dena gold accent swap (Settings > Appearance > Accent).
const Color brutalGold = Color(0xFFF1C40F);

/// What marks focus and selection: hazard yellow (default) or Dena gold.
enum BrutalAccent {
  hazard(brutalHazard),
  gold(brutalGold);

  const BrutalAccent(this.color);

  final Color color;
}

/// How dense the layout is; only metrics change, never colours.
enum BrutalDensity {
  /// Touch: 48 px rows, 46 px buttons, 4 px shadows.
  phone,

  /// The 640x480 D-pad handheld: 28 px rows, 3 px shadows.
  handheld,

  /// Mouse, keyboard and controller (before TV scale): 40 px rows.
  desktop;

  /// The density for [context]: a handheld launcher, the desktop runner, or
  /// a phone.
  static BrutalDensity of(BuildContext context) {
    if (Handheld.of(context)) return handheld;
    return shellProfile == ShellProfile.desktop ? desktop : phone;
  }
}

/// Every Brutalist design value. Registered on the theme by `denaTheme()`.
@immutable
class BrutalTokens extends ThemeExtension<BrutalTokens> {
  const BrutalTokens({
    required this.dark,
    required this.ground,
    required this.gridLine,
    required this.gridLineMajor,
    required this.panel,
    required this.ink,
    required this.shadow,
    required this.muted,
    required this.mutedText,
    required this.focus,
    required this.onFocus,
    required this.primary,
    required this.onPrimary,
    required this.danger,
    required this.ok,
    required this.headerBar,
    required this.onHeaderBar,
    this.density = BrutalDensity.phone,
  });

  /// Paper: graph paper, black ink. The default mode.
  factory BrutalTokens.paper({BrutalAccent accent = BrutalAccent.hazard}) =>
      BrutalTokens(
        dark: false,
        ground: const Color(0xFFF2F2EC),
        gridLine: const Color(0x12000000), // 7 %
        gridLineMajor: const Color(0x1F000000), // 12 %
        panel: const Color(0xFFFFFFFF),
        ink: const Color(0xFF000000),
        shadow: const Color(0xFF000000),
        muted: const Color(0xFFCFCFC8),
        mutedText: const Color(0xFF5A5A55),
        focus: accent.color,
        onFocus: const Color(0xFF000000),
        primary: const Color(0xFF1F3BFF),
        onPrimary: const Color(0xFFFFFFFF),
        danger: const Color(0xFFE10600),
        ok: const Color(0xFF00A33A),
        headerBar: const Color(0xFF000000),
        onHeaderBar: const Color(0xFFF2F2EC),
      );

  /// Ink: the dark mode, paper-white ink on black.
  factory BrutalTokens.ink({BrutalAccent accent = BrutalAccent.hazard}) =>
      BrutalTokens(
        dark: true,
        ground: const Color(0xFF0E0E0E),
        gridLine: const Color(0x12FFFFFF),
        gridLineMajor: const Color(0x1FFFFFFF),
        panel: const Color(0xFF000000),
        ink: const Color(0xFFF2F2EC),
        shadow: const Color(0xFFF2F2EC),
        muted: const Color(0xFF3A3A36),
        mutedText: const Color(0xFFA4A49C),
        focus: accent.color,
        onFocus: const Color(0xFF000000),
        primary: const Color(0xFF4A63FF),
        onPrimary: const Color(0xFFFFFFFF),
        danger: const Color(0xFFFF3B30),
        ok: const Color(0xFF2BD46A),
        headerBar: const Color(0xFFF2F2EC),
        onHeaderBar: const Color(0xFF000000),
      );

  /// The tokens for [brightness]: Ink when dark, Paper when light.
  factory BrutalTokens.forBrightness(
    Brightness brightness, {
    BrutalAccent accent = BrutalAccent.hazard,
  }) => brightness == Brightness.dark
      ? BrutalTokens.ink(accent: accent)
      : BrutalTokens.paper(accent: accent);

  /// The theme's tokens at [context]'s density. Outside a Dena theme
  /// (bare widget tests) Paper.
  static BrutalTokens of(BuildContext context) {
    final t =
        Theme.of(context).extension<BrutalTokens>() ?? BrutalTokens.paper();
    final d = BrutalDensity.of(context);
    return t.density == d ? t : t.copyWith(density: d);
  }

  // ---- colour (2.1) ---------------------------------------------------------

  /// Whether this is the Ink (dark) set.
  final bool dark;

  /// Screen background: graph paper.
  final Color ground;

  /// The 8 px graph grid's 1 px lines.
  final Color gridLine;

  /// Every 4th grid line.
  final Color gridLineMajor;

  /// Tables, buttons, dialogs.
  final Color panel;

  /// Text, borders, icons.
  final Color ink;

  /// Hard offset shadows (always the ink colour).
  final Color shadow;

  /// Disabled fills, empty progress, dividers inside panels.
  final Color muted;

  /// Secondary text (at least 4.5:1 on [panel]).
  final Color mutedText;

  /// The focused or selected fill.
  final Color focus;

  /// Text on [focus]: always black.
  final Color onFocus;

  /// The primary action fill (PLAY, RESUME), the focus arrow cell.
  final Color primary;

  /// Text on [primary].
  final Color onPrimary;

  /// Delete and quit text, hazard stripes.
  final Color danger;

  /// `... ok` log lines, sync done.
  final Color ok;

  /// Table header rows and key columns.
  final Color headerBar;

  /// Text on [headerBar].
  final Color onHeaderBar;

  /// The layout density these metrics are for.
  final BrutalDensity density;

  // ---- space (2.3) ----------------------------------------------------------

  static const double s1 = 4, s2 = 8, s3 = 12, s4 = 16, s6 = 24, s8 = 32;

  /// The graph paper cell.
  static const double gridCell = 8;

  /// Panels, buttons, tables.
  static const double border = 3;

  /// Table row dividers, inner cells.
  static const double borderThin = 2;

  /// Grid paper only.
  static const double hairline = 1;

  /// The only corner radius.
  static const BorderRadius radius = BorderRadius.zero;

  /// The hard shadow under buttons and small panels.
  Offset get shadowOffset => density == BrutalDensity.handheld
      ? const Offset(3, 3)
      : const Offset(4, 4);

  /// The hard shadow under tables and dialogs.
  Offset get shadowOffsetLarge => density == BrutalDensity.handheld
      ? const Offset(4, 4)
      : const Offset(6, 6);

  /// A table row's height.
  double get rowHeight => switch (density) {
    BrutalDensity.phone => 48,
    BrutalDensity.handheld => 28,
    BrutalDensity.desktop => 40,
  };

  /// A button's height.
  double get buttonHeight => switch (density) {
    BrutalDensity.phone => 46,
    BrutalDensity.handheld => 30,
    BrutalDensity.desktop => 38,
  };

  /// Icon size: multiples of the 9-cell pixel grid.
  static const double iconSize = 18;

  /// Icon size in navigation tabs.
  static const double iconSizeLarge = 27;

  /// Whether pad devices draw the `<-` marker beside a focused button.
  bool get padMarkers => density != BrutalDensity.phone;

  // ---- motion (2.4) ---------------------------------------------------------

  /// A pressed button springs back in this time (press itself is instant).
  static const Duration release = Duration(milliseconds: 60);

  /// One step of a stepped animation.
  static const Duration step = Duration(milliseconds: 70);

  /// The longest fade allowed.
  static const Duration maxFade = Duration(milliseconds: 80);

  /// The text-field cursor blink step.
  static const Duration blink = Duration(milliseconds: 500);

  /// Instant scrim behind sheets and dialogs.
  static const Color scrim = Color(0x66000000);

  // ---- type (2.2) -----------------------------------------------------------

  TextStyle _mono(double size, double height, FontWeight w, {double? ls}) =>
      TextStyle(
        fontFamily: brutalMono,
        fontFamilyFallback: brutalFallback,
        fontSize: size,
        height: height / size,
        fontWeight: w,
        letterSpacing: ls ?? 0,
        color: ink,
      );

  TextStyle _display(double size, double height) => TextStyle(
    fontFamily: brutalDisplay,
    fontFamilyFallback: const [brutalMono, ...brutalFallback],
    fontSize: size,
    height: height / size,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    color: ink,
  );

  /// Archivo Black 40/44, UPPERCASE.
  TextStyle get display => _display(40, 44);

  /// Archivo Black 28/32, UPPERCASE.
  TextStyle get displaySmall => _display(28, 32);

  /// Plex Mono 18/24 600, UPPERCASE.
  TextStyle get title => _mono(18, 24, FontWeight.w600);

  /// Plex Mono 14/20 500.
  TextStyle get body => _mono(14, 20, FontWeight.w500);

  /// Table cells: Plex Mono 14/18 600.
  TextStyle get row => _mono(14, 18, FontWeight.w600);

  /// Buttons, tabs, headers: Plex Mono 13/16 600, UPPERCASE, spaced 0.5.
  TextStyle get label => _mono(13, 16, FontWeight.w600, ls: 0.5);

  /// Meta, hints, logs: Plex Mono 11/14 500.
  TextStyle get small => _mono(11, 14, FontWeight.w500);

  /// The whole type scale mapped onto Material's [TextTheme], so screens
  /// not yet converted come out in mono.
  TextTheme get textTheme => TextTheme(
    displayLarge: display,
    displayMedium: display,
    displaySmall: displaySmall,
    headlineLarge: displaySmall,
    headlineMedium: title,
    headlineSmall: title,
    titleLarge: title,
    titleMedium: title.copyWith(fontSize: 15, height: 20 / 15),
    titleSmall: label,
    bodyLarge: body,
    bodyMedium: body,
    bodySmall: small,
    labelLarge: label,
    labelMedium: label.copyWith(fontSize: 12, height: 15 / 12),
    labelSmall: small.copyWith(fontWeight: FontWeight.w600),
  );

  // ---- decoration helpers ---------------------------------------------------

  /// A panel: fill, 3 px ink border, hard shadow ([large] for tables and
  /// dialogs; [shadowed] false for flat inner boxes).
  BoxDecoration panelDecoration({
    Color? fill,
    bool large = false,
    bool shadowed = true,
    Color? borderColor,
  }) => BoxDecoration(
    color: fill ?? panel,
    border: Border.all(color: borderColor ?? ink, width: border),
    boxShadow: shadowed
        ? [
            BoxShadow(
              color: shadow,
              offset: large ? shadowOffsetLarge : shadowOffset,
            ),
          ]
        : null,
  );

  /// Converts a title to the table's file-name style: upper case, spaces to
  /// underscores. Display only; the stored title never changes.
  static String fileName(String title) =>
      title.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '_');

  @override
  BrutalTokens copyWith({
    Color? focus,
    BrutalDensity? density,
  }) => BrutalTokens(
    dark: dark,
    ground: ground,
    gridLine: gridLine,
    gridLineMajor: gridLineMajor,
    panel: panel,
    ink: ink,
    shadow: shadow,
    muted: muted,
    mutedText: mutedText,
    focus: focus ?? this.focus,
    onFocus: onFocus,
    primary: primary,
    onPrimary: onPrimary,
    danger: danger,
    ok: ok,
    headerBar: headerBar,
    onHeaderBar: onHeaderBar,
    density: density ?? this.density,
  );

  /// Tokens switch with the theme mode: a hard cut, but colours lerp so
  /// AnimatedTheme stays valid.
  @override
  BrutalTokens lerp(BrutalTokens? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return BrutalTokens(
      dark: t < 0.5 ? dark : other.dark,
      ground: c(ground, other.ground),
      gridLine: c(gridLine, other.gridLine),
      gridLineMajor: c(gridLineMajor, other.gridLineMajor),
      panel: c(panel, other.panel),
      ink: c(ink, other.ink),
      shadow: c(shadow, other.shadow),
      muted: c(muted, other.muted),
      mutedText: c(mutedText, other.mutedText),
      focus: c(focus, other.focus),
      onFocus: c(onFocus, other.onFocus),
      primary: c(primary, other.primary),
      onPrimary: c(onPrimary, other.onPrimary),
      danger: c(danger, other.danger),
      ok: c(ok, other.ok),
      headerBar: c(headerBar, other.headerBar),
      onHeaderBar: c(onHeaderBar, other.onHeaderBar),
      density: t < 0.5 ? density : other.density,
    );
  }

  /// Interpolates an offset; used by press animations.
  static Offset lerpOffset(Offset a, Offset b, double t) =>
      Offset(lerpDouble(a.dx, b.dx, t)!, lerpDouble(a.dy, b.dy, t)!);
}
