import 'dart:io';

import 'package:dena_emu/src/app.dart';
import 'package:dena_emu/src/ui/app_theme.dart';
import 'package:dena_emu/src/ui/brutal/tokens.dart';
import 'package:dena_emu/src/ui/theme_settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('schemes', () {
    for (final accent in BrutalAccent.values) {
      for (final (name, t) in [
        ('paper', BrutalTokens.paper(accent: accent)),
        ('ink', BrutalTokens.ink(accent: accent)),
      ]) {
        test('$name ${accent.name}: text stays readable (WCAG AA)', () {
          void aa(Color fg, Color bg, String what, [double min = 4.5]) =>
              expect(
                contrastRatio(fg, bg),
                greaterThanOrEqualTo(min),
                reason: '$what on $name ${accent.name}',
              );
          aa(t.ink, t.ground, 'ink on ground');
          aa(t.ink, t.panel, 'ink on panel');
          aa(t.mutedText, t.panel, 'muted text');
          aa(t.onFocus, t.focus, 'focus');
          aa(t.onPrimary, t.primary, 'primary');
          aa(t.onHeaderBar, t.headerBar, 'header bar');
          aa(t.danger, t.panel, 'danger', 3);

          final s = brutalScheme(t);
          expect(s.brightness, t.dark ? Brightness.dark : Brightness.light);
          aa(s.onSurface, s.surface, 'onSurface');
          aa(s.onPrimary, s.primary, 'onPrimary');
          aa(s.onSecondaryContainer, s.secondaryContainer, 'nav indicator');
        });
      }
    }

    test('the accent sets the focus fill', () {
      expect(BrutalTokens.paper().focus, brutalHazard);
      expect(BrutalTokens.paper(accent: BrutalAccent.gold).focus, brutalGold);
      expect(BrutalTokens.ink(accent: BrutalAccent.gold).focus, brutalGold);
    });
  });

  group('ThemeSettings', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('theme'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('defaults to Paper and Hazard and round-trips the file', () {
      final file = File('${dir.path}/theme.json');
      final s = ThemeSettings.load(file);
      expect(s.mode, ThemeMode.light);
      expect(s.accent, BrutalAccent.hazard);
      expect(s.library, LibraryView.table);
      s
        ..mode = ThemeMode.dark
        ..accent = BrutalAccent.gold
        ..library = LibraryView.stash;
      final again = ThemeSettings.load(file);
      expect(again.mode, ThemeMode.dark);
      expect(again.accent, BrutalAccent.gold);
      expect(again.library, LibraryView.stash);
      expect(file.readAsStringSync(), contains('"mode":"ink"'));
    });

    test('an old theme.json migrates: dark to Ink, palette dropped', () {
      final file = File('${dir.path}/theme.json')
        ..writeAsStringSync(
          '{"mode":"dark","palette":"gbc_teal","stash":true,'
          '"audioLatencyMs":20}',
        );
      final s = ThemeSettings.load(file);
      expect(s.mode, ThemeMode.dark);
      expect(s.accent, BrutalAccent.hazard);
      expect(s.audioLatencyMs, 20);
      file.writeAsStringSync('{"mode":"light"}');
      expect(ThemeSettings.load(file).mode, ThemeMode.light);
    });

    test('a damaged file gives the defaults', () {
      final file = File('${dir.path}/theme.json')..writeAsStringSync('{"mode"');
      final s = ThemeSettings.load(file);
      expect(s.mode, ThemeMode.light);
      expect(s.accent, BrutalAccent.hazard);
    });
  });

  testWidgets('the app starts on Paper with the Brutalist tokens', (
    tester,
  ) async {
    await tester.pumpWidget(const DenaApp(home: Scaffold()));
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    expect(theme.brightness, Brightness.light);
    final t = theme.extension<BrutalTokens>()!;
    expect(t.dark, isFalse);
    expect(t.focus, brutalHazard);
    expect(theme.textTheme.bodyMedium!.fontFamily, brutalMono);
  });

  testWidgets('choosing Ink and Gold restyles the app', (tester) async {
    final settings = ThemeSettings();
    tester.view.physicalSize = const Size(412, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DenaApp(theme: settings, home: const ThemeSettingsPage()),
    );
    await tester.tap(find.text(' INK '));
    await tester.pumpAndSettle();
    await tester.tap(find.text(' GOLD '));
    await tester.pumpAndSettle();
    expect(settings.mode, ThemeMode.dark);
    expect(settings.accent, BrutalAccent.gold);
    final theme = Theme.of(tester.element(find.text('[GOLD]')));
    expect(theme.brightness, Brightness.dark);
    expect(theme.extension<BrutalTokens>()!.focus, brutalGold);
    expect(themeSummary(settings), 'Ink · Gold');
  });
}
