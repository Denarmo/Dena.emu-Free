// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'apps/builtin_apps.dart';
import 'desktop/desktop_startup.dart';
import 'media/music_screen.dart';
import 'media/video_screen.dart';
import 'shell/platform_features.dart';
import 'shell/handheld.dart';
import 'shell/power_link.dart';
import 'ui/app_theme.dart';
import 'ui/brutal/brutal.dart';
import 'ui/dena_icons.dart';
import 'ui/onscreen_keyboard.dart';

/// The app theme: Brutalist over Material 3 (brutalist-ui.md). Every
/// Material component reads the [BrutalTokens] for [t]: square shapes,
/// 3 px ink borders, hard offset shadows, mono type, yellow focus, no
/// ripples and hard-cut page changes, so screens not yet rebuilt from the
/// kit in `ui/brutal/` already look Brutalist.
ThemeData denaTheme(BrutalTokens t) {
  final scheme = brutalScheme(t);
  final text = t.textTheme.apply(bodyColor: t.ink, displayColor: t.ink);
  final ink = BorderSide(color: t.ink, width: BrutalTokens.border);
  final thin = BorderSide(color: t.ink, width: BrutalTokens.borderThin);
  final panel = BrutalBorder(
    side: ink,
    shadowOffset: t.shadowOffset,
    shadowColor: t.shadow,
  );
  final panelLarge = BrutalBorder(
    side: ink,
    shadowOffset: t.shadowOffsetLarge,
    shadowColor: t.shadow,
  );
  const square = RoundedRectangleBorder();
  bool lit(Set<WidgetState> s) =>
      s.contains(WidgetState.focused) || s.contains(WidgetState.hovered);
  const noTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: BrutalPageTransitions(),
      TargetPlatform.iOS: BrutalPageTransitions(),
      TargetPlatform.linux: BrutalPageTransitions(),
      TargetPlatform.windows: BrutalPageTransitions(),
      TargetPlatform.macOS: BrutalPageTransitions(),
      TargetPlatform.fuchsia: BrutalPageTransitions(),
    },
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: ink,
  );
  return ThemeData(
    colorScheme: scheme,
    extensions: [t],
    // Denser than the M3 default: we design for 640x480 first (CLAUDE.md §5).
    visualDensity: VisualDensity.compact,
    fontFamily: brutalMono,
    fontFamilyFallback: brutalFallback,
    textTheme: text,
    // Presses move onto the shadow: no ripples, no tints.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    focusColor: t.focus,
    hoverColor: t.focus.withValues(alpha: 0.5),
    scaffoldBackgroundColor: t.ground,
    canvasColor: t.panel,
    cardColor: t.panel,
    dividerColor: t.muted,
    disabledColor: t.mutedText,
    pageTransitionsTheme: noTransitions,
    iconTheme: IconThemeData(color: t.ink, size: BrutalTokens.iconSize),
    primaryIconTheme: IconThemeData(
      color: t.onPrimary,
      size: BrutalTokens.iconSize,
    ),
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) => const Icon(DenaIcons.arrowBack),
      closeButtonIconBuilder: (_) => const Icon(DenaIcons.close),
      drawerButtonIconBuilder: (_) => const Icon(DenaIcons.menu),
      endDrawerButtonIconBuilder: (_) => const Icon(DenaIcons.menu),
    ),
    cardTheme: CardThemeData(
      color: t.panel,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: panel,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: brutalButtonStyle(t, variant: BrutalButtonVariant.primary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: brutalButtonStyle(t)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: brutalButtonStyle(t)),
    textButtonTheme: TextButtonThemeData(
      style: brutalButtonStyle(t, flat: true),
    ),
    iconButtonTheme: IconButtonThemeData(style: brutalIconButtonStyle(t)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: t.primary,
      foregroundColor: t.onPrimary,
      focusColor: t.focus,
      hoverColor: t.focus,
      splashColor: Colors.transparent,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: panel,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      selectedIcon: const Icon(DenaIcons.check),
      style: ButtonStyle(
        splashFactory: NoSplash.splashFactory,
        animationDuration: Duration.zero,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        textStyle: WidgetStatePropertyAll(t.label),
        shape: const WidgetStatePropertyAll(square),
        side: WidgetStatePropertyAll(ink),
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) || lit(s) ? t.focus : t.panel,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? t.mutedText
              : (s.contains(WidgetState.selected) || lit(s)
                    ? t.onFocus
                    : t.ink),
        ),
        iconColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) || lit(s) ? t.onFocus : t.ink,
        ),
      ),
    ),
    toggleButtonsTheme: ToggleButtonsThemeData(
      borderRadius: BorderRadius.zero,
      borderColor: t.ink,
      selectedBorderColor: t.ink,
      borderWidth: BrutalTokens.borderThin,
      fillColor: t.focus,
      selectedColor: t.onFocus,
      color: t.ink,
      focusColor: t.focus,
      splashColor: Colors.transparent,
      textStyle: t.label,
    ),
    chipTheme: ChipThemeData(
      shape: square,
      side: thin,
      showCheckmark: false,
      elevation: 0,
      pressElevation: 0,
      backgroundColor: t.panel,
      selectedColor: t.focus,
      disabledColor: t.muted,
      labelStyle: t.label,
      secondaryLabelStyle: t.label.copyWith(color: t.onFocus),
      iconTheme: IconThemeData(color: t.ink, size: BrutalTokens.iconSize),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: square,
      side: thin,
      splashRadius: 0,
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.ink : t.panel,
      ),
      checkColor: WidgetStatePropertyAll(t.panel),
      overlayColor: WidgetStateProperty.resolveWith(
        (s) => lit(s) ? t.focus : Colors.transparent,
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStatePropertyAll(t.ink),
      splashRadius: 0,
      overlayColor: WidgetStateProperty.resolveWith(
        (s) => lit(s) ? t.focus : Colors.transparent,
      ),
    ),
    // The stock switch keeps its stadium; screens move to CfgToggle.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.panel : t.ink,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.ink : t.panel,
      ),
      trackOutlineColor: WidgetStatePropertyAll(t.ink),
      trackOutlineWidth: const WidgetStatePropertyAll(BrutalTokens.borderThin),
      overlayColor: WidgetStateProperty.resolveWith(
        (s) => lit(s) ? t.focus : Colors.transparent,
      ),
      thumbIcon: const WidgetStatePropertyAll(null),
      splashRadius: 0,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 8,
      trackShape: const RectangularSliderTrackShape(),
      activeTrackColor: t.ink,
      inactiveTrackColor: t.muted,
      disabledActiveTrackColor: t.mutedText,
      disabledInactiveTrackColor: t.muted,
      thumbColor: t.focus,
      thumbShape: BrutalSliderThumb(fill: t.focus, border: t.ink),
      overlayShape: SliderComponentShape.noOverlay,
      tickMarkShape: SliderTickMarkShape.noTickMark,
      valueIndicatorColor: t.headerBar,
      valueIndicatorTextStyle: t.label.copyWith(color: t.onHeaderBar),
      valueIndicatorShape: const RectangularSliderValueIndicatorShape(),
      showValueIndicator: ShowValueIndicator.onDrag,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: t.ink,
      linearTrackColor: t.muted,
      circularTrackColor: t.muted,
      linearMinHeight: 8,
      borderRadius: BorderRadius.zero,
      strokeCap: StrokeCap.butt,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: t.panel,
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: t.primary, width: BrutalTokens.border),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: t.danger, width: BrutalTokens.border),
      ),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: t.danger, width: BrutalTokens.border),
      ),
      disabledBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: t.muted, width: BrutalTokens.border),
      ),
      labelStyle: t.label.copyWith(color: t.mutedText),
      floatingLabelStyle: t.label,
      hintStyle: t.body.copyWith(color: t.mutedText),
      helperStyle: t.small.copyWith(color: t.mutedText),
      errorStyle: t.small.copyWith(color: t.danger),
      prefixIconColor: t.ink,
      suffixIconColor: t.ink,
      isDense: true,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: t.ink,
      selectionColor: t.focus,
      selectionHandleColor: t.ink,
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(t.panel),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: const WidgetStatePropertyAll(square),
      side: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.focused)
            ? BorderSide(color: t.primary, width: BrutalTokens.border)
            : ink,
      ),
      textStyle: WidgetStatePropertyAll(t.body),
      hintStyle: WidgetStatePropertyAll(t.body.copyWith(color: t.mutedText)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: BrutalTokens.s3),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: t.ground,
      foregroundColor: t.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: ink),
      titleTextStyle: t.title,
      toolbarTextStyle: t.body,
      iconTheme: IconThemeData(color: t.ink, size: BrutalTokens.iconSize),
      actionsIconTheme: IconThemeData(
        color: t.ink,
        size: BrutalTokens.iconSize,
      ),
    ),
    tabBarTheme: TabBarThemeData(
      indicator: BoxDecoration(
        color: t.focus,
        border: Border.all(color: t.ink, width: BrutalTokens.borderThin),
      ),
      indicatorSize: TabBarIndicatorSize.tab,
      labelColor: t.onFocus,
      unselectedLabelColor: t.ink,
      labelStyle: t.label,
      unselectedLabelStyle: t.label,
      dividerColor: t.ink,
      dividerHeight: BrutalTokens.borderThin,
      overlayColor: WidgetStateProperty.resolveWith(
        (s) => lit(s) ? t.focus.withValues(alpha: 0.5) : Colors.transparent,
      ),
      splashFactory: NoSplash.splashFactory,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: t.focus,
      indicatorShape: Border.fromBorderSide(thin),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? t.onFocus : t.ink,
          size: BrutalTokens.iconSize,
        ),
      ),
      labelTextStyle: WidgetStatePropertyAll(t.label),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: t.panel,
      indicatorColor: t.focus,
      indicatorShape: Border.fromBorderSide(thin),
      selectedIconTheme: IconThemeData(
        color: t.onFocus,
        size: BrutalTokens.iconSize,
      ),
      unselectedIconTheme: IconThemeData(
        color: t.ink,
        size: BrutalTokens.iconSize,
      ),
      selectedLabelTextStyle: t.label,
      unselectedLabelTextStyle: t.label,
    ),
    dividerTheme: DividerThemeData(
      color: t.muted,
      thickness: BrutalTokens.borderThin,
      space: BrutalTokens.borderThin,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: t.ink,
      textColor: t.ink,
      selectedColor: t.onFocus,
      selectedTileColor: t.focus,
      titleTextStyle: t.label.copyWith(fontSize: 14, height: 18 / 14),
      subtitleTextStyle: t.small.copyWith(color: t.mutedText),
      leadingAndTrailingTextStyle: t.label,
      shape: square,
      minVerticalPadding: 6,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      iconColor: t.ink,
      collapsedIconColor: t.ink,
      textColor: t.ink,
      collapsedTextColor: t.ink,
      shape: square,
      collapsedShape: square,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.panel,
      modalBackgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: BrutalTokens.scrim,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: false,
      dragHandleColor: t.ink,
      shape: Border(top: ink),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      barrierColor: BrutalTokens.scrim,
      shape: panelLarge,
      titleTextStyle: t.title,
      contentTextStyle: t.body,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: panel,
      textStyle: t.label,
      labelTextStyle: WidgetStatePropertyAll(t.label),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(panel),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: t.body,
      inputDecorationTheme: InputDecorationThemeData(border: inputBorder),
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(t.panel),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(panel),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: const BoxDecoration(color: Color(0xFF000000)),
      textStyle: t.small.copyWith(color: const Color(0xFFFFFFFF)),
      waitDuration: const Duration(milliseconds: 400),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: t.focus,
      textColor: t.onFocus,
      textStyle: t.small.copyWith(fontWeight: FontWeight.w700),
    ),
    snackBarTheme: brutalSnackBarTheme(t),
    drawerTheme: DrawerThemeData(
      backgroundColor: t.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: Border(right: ink),
      endShape: Border(left: ink),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(t.ink),
      radius: Radius.zero,
      thickness: const WidgetStatePropertyAll(6),
    ),
  );
}

class DenaApp extends StatefulWidget {
  const DenaApp({super.key, required this.home, this.theme});

  /// The first screen; tests mount any screen inside the real app theme.
  final Widget home;

  /// The saved theme choices (theming.md); null keeps the defaults (Paper,
  /// hazard accent) for the session.
  final ThemeSettings? theme;

  @override
  State<DenaApp> createState() => _DenaAppState();
}

class _DenaAppState extends State<DenaApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// The handheld power daemon (power-daemon.md); null elsewhere.
  PowerLink? _power;

  late final ThemeSettings _theme = widget.theme ?? ThemeSettings();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final link = PowerScope.of(context);
    if (link == _power) return;
    _releasePower();
    _power = link?..onBatteryLow = _batteryLow;
    if (link != null) HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _batteryLow() => _messenger.currentState
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text('Battery low: plug in soon. Your game saves first.'),
      ),
    );

  /// Any button keeps the idle-sleep timer from running out.
  bool _onKey(KeyEvent event) {
    _power?.activity();
    return false;
  }

  void _releasePower() {
    final link = _power;
    if (link == null) return;
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (link.onBatteryLow == _batteryLow) link.onBatteryLow = null;
  }

  @override
  void dispose() {
    _releasePower();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _theme,
      builder: (context, _) => ThemeScope(
        settings: _theme,
        child: _app(
          BrutalTokens.paper(accent: _theme.accent),
          BrutalTokens.ink(accent: _theme.accent),
        ),
      ),
    );
  }

  Widget _app(BrutalTokens light, BrutalTokens dark) {
    return MaterialApp(
      navigatorKey: _navigator,
      scaffoldMessengerKey: _messenger,
      title: 'Dena.emu',
      debugShowCheckedModeBanner: false,
      theme: denaTheme(light),
      darkTheme: denaTheme(dark),
      themeMode: _theme.mode,
      onGenerateRoute: builtInAppRouteFor,
      // B goes back everywhere (handheld-ui.md); A activates by default.
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.gameButtonB):
            const BackIntent(),
        // Keyboard on Windows and SteamOS: Esc and Backspace are B
        // (brutalist-ui.md 4.12). Text fields keep Backspace (their own
        // shortcuts sit nearer the focus); a running game turns the pop into
        // its pause menu.
        if (shellProfile == ShellProfile.desktop) ...{
          const SingleActivator(LogicalKeyboardKey.escape): const BackIntent(),
          const SingleActivator(LogicalKeyboardKey.backspace):
              const BackIntent(),
        },
      },
      actions: {
        ...WidgetsApp.defaultActions,
        BackIntent: CallbackAction<BackIntent>(
          onInvoke: (_) => _navigator.currentState?.maybePop(),
        ),
      },
      // Controller mode on the desktop scales up for the TV and takes the
      // handheld's D-pad rules (controller-mode.md).
      // The same widgets either way, so the routes keep their state when
      // controller mode turns on or off.
      builder: (context, child) {
        final buttons = usesButtons(context);
        return ControllerTvLayout(
          child: Shortcuts(
            shortcuts: buttons ? handheldArrows : const {},
            child: HandheldTextEntry(enabled: buttons, child: child!),
          ),
        );
      },
      home: widget.home,
      // Self-contained apps (media-players.md).
      routes: {
        musicRoute: (_) => const MusicScreen(),
        videoRoute: (_) => const VideoScreen(),
      },
    );
  }
}
