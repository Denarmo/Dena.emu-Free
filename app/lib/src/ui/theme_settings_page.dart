// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Theme: Paper / Ink / System, and the accent (hazard yellow or
// Dena gold), and the library view.
// Spec: docs/specs/theming.md, docs/specs/brutalist-ui.md (4.6)
import 'package:material_ui/material_ui.dart';

import '../shell/cfg_page.dart';
import 'app_theme.dart';
import 'brutal/brutal.dart';

/// "Paper · Hazard": the Settings row's subtitle.
String themeSummary(ThemeSettings settings) =>
    '${modeLabel(settings.mode)} · ${accentLabel(settings.accent)}';

/// Paper, Ink or System.
String modeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'Paper',
  ThemeMode.dark => 'Ink',
  ThemeMode.system => 'System',
};

/// Hazard or Gold.
String accentLabel(BrutalAccent accent) => switch (accent) {
  BrutalAccent.hazard => 'Hazard',
  BrutalAccent.gold => 'Gold',
};

/// Table, Grid or Stash.
String libraryViewLabel(LibraryView view) => switch (view) {
  LibraryView.table => 'Table',
  LibraryView.grid => 'Grid',
  LibraryView.stash => 'Stash',
};

/// `APPEARANCE.CFG`: mode, accent and library view, each a [CfgSegment].
/// [autofocus] puts the D-pad on the mode when nothing has focus yet.
class AppearanceCfg extends StatelessWidget {
  const AppearanceCfg({super.key, this.autofocus = false});

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final settings = ThemeScope.of(context).notifier!;
    return LayoutBuilder(
      builder: (context, box) {
        // A three-way segment leaves no room for the label on a phone, so
        // narrow tables put the segment under its label.
        final narrow = box.maxWidth < 480;
        Widget row(String label, Widget control) => narrow
            ? _StackedRow(label: label, control: control)
            : CfgRow(label: label, control: control);
        return _table(settings, row);
      },
    );
  }

  Widget _table(ThemeSettings settings, Widget Function(String, Widget) row) {
    return CfgTable(
      header: 'APPEARANCE.CFG',
      rows: [
        row(
          'Mode',
          AutofocusFirst(
            enabled: autofocus,
            child: CfgSegment<ThemeMode>(
              values: const [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
              selected: settings.mode,
              labelOf: modeLabel,
              onChanged: (m) => settings.mode = m,
            ),
          ),
        ),
        row(
          'Accent',
          CfgSegment<BrutalAccent>(
            values: BrutalAccent.values,
            selected: settings.accent,
            labelOf: accentLabel,
            onChanged: (a) => settings.accent = a,
          ),
        ),
        row(
          'Library',
          CfgSegment<LibraryView>(
            values: LibraryView.values,
            selected: settings.library,
            labelOf: libraryViewLabel,
            onChanged: (v) => settings.library = v,
          ),
        ),
      ],
    );
  }
}

/// A [CfgRow] with its control on a line of its own, for narrow screens.
class _StackedRow extends StatelessWidget {
  const _StackedRow({required this.label, required this.control});

  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: BrutalTokens.s3,
        vertical: BrutalTokens.s2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: t.label.copyWith(color: t.ink)),
          const SizedBox(height: BrutalTokens.s1),
          control,
        ],
      ),
    );
  }
}

/// Settings > Appearance as a page of its own (the root shows the same
/// table inline).
class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const CfgPage(
    title: 'Appearance',
    path: ['settings', 'appearance.cfg'],
    sections: [AppearanceCfg(autofocus: true)],
  );
}
