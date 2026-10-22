// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Audio latency: the buffer target the audio path aims for.
// Spec: docs/specs/performance.md, docs/specs/brutalist-ui.md (4.11)
import 'package:material_ui/material_ui.dart';

import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import 'app_theme.dart';
import 'brutal/brutal.dart';

/// The choice's label ("Normal", "Low", ...), for the Settings row and page.
String audioLatencyLabel(int ms) => switch (ms) {
  30 => 'Low',
  20 => 'Lowest, may crackle',
  _ => 'Normal',
};

/// Settings > Audio > Latency: a picker table with the buffer sizes.
class AudioLatencyPage extends StatelessWidget {
  const AudioLatencyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = ThemeScope.of(context).notifier!;
    const options = audioLatencyOptions;
    final current = options.indexOf(settings.audioLatencyMs);
    return Shortcuts(
      shortcuts: arrowsMoveFocus,
      child: CfgPage(
        title: 'Audio latency',
        path: const ['settings', 'audio.cfg', 'latency'],
        sections: [
          BrutalTable(
            shrinkWrap: true,
            columns: const [
              BrutalColumn('', width: 44),
              BrutalColumn('Buffer', flex: 1),
              BrutalColumn('ms', width: 56, numeric: true),
            ],
            rowCount: options.length,
            selectedRow: current < 0 ? null : current,
            // The D-pad starts on the current choice.
            autofocusRow: current < 0 ? 0 : current,
            onRowPressed: (i) => settings.audioLatencyMs = options[i],
            cellBuilder: (context, row, column, lit) => Text(switch (column) {
              0 => row == current ? '[x]' : '[ ]',
              1 => audioLatencyLabel(options[row]).toUpperCase(),
              _ => '${options[row]}',
            }),
          ),
          const LogLine(
            '> a smaller buffer answers sooner but may crackle on slow '
            'devices.',
          ),
        ],
      ),
    );
  }
}
