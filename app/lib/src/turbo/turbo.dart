// SPDX-License-Identifier: GPL-3.0-or-later
// Turbo fire: which buttons repeat while held, globally and per game.
// Spec: docs/specs/turbo.md, docs/specs/brutalist-ui.md (4.6)
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../shell/cfg_page.dart';
import '../ui/brutal/brutal.dart';

/// Buttons that can be turbo, as libretro joypad bits.
const turboButtons = <(String, int)>[
  ('A', 1 << 8),
  ('B', 1 << 0),
  ('X', 1 << 9),
  ('Y', 1 << 1),
  ('L', 1 << 10),
  ('R', 1 << 11),
];

/// Presses per second offered, and frames per half cycle at 60 fps.
const turboRates = <(int, int)>[(30, 1), (15, 2), (10, 3), (7, 4)];

/// Default rate: 15 presses per second.
const defaultTurboRate = 15;

/// Frames each half of a press cycle lasts for [rate] presses per second.
int turboHalfFrames(int rate) =>
    turboRates.firstWhere((r) => r.$1 == rate, orElse: () => (15, 2)).$2;

/// One turbo setup: the button bits and a rate in presses per second.
typedef TurboConfig = ({int mask, int rate});

const TurboConfig turboOff = (mask: 0, rate: defaultTurboRate);

/// `<dataDir>/turbo.json`, shaped as
/// `{"global": {"mask": 0, "rate": 15}, "games": {"<sha1>": {...}}}`.
/// A game entry replaces the global one for that game.
class TurboStore {
  TurboStore(this.dataDir);

  final String dataDir;

  File get _file => File(p.join(dataDir, 'turbo.json'));

  static TurboConfig _config(Object? j) {
    if (j is! Map) return turboOff;
    final mask = j['mask'];
    final rate = j['rate'];
    final allowed = turboButtons.fold<int>(0, (a, b) => a | b.$2);
    return (
      mask: mask is int ? mask & allowed : 0,
      rate: rate is int && turboRates.any((r) => r.$1 == rate)
          ? rate
          : defaultTurboRate,
    );
  }

  static Map<String, int> _json(TurboConfig c) => {
    'mask': c.mask,
    'rate': c.rate,
  };

  ({TurboConfig global, Map<String, TurboConfig> games}) _read() {
    final empty = (global: turboOff, games: <String, TurboConfig>{});
    try {
      if (!_file.existsSync()) return empty;
      final j = jsonDecode(_file.readAsStringSync());
      if (j is! Map) return empty;
      final games = j['games'];
      return (
        global: _config(j['global']),
        games: {
          if (games is Map)
            for (final e in games.entries) '${e.key}': _config(e.value),
        },
      );
    } on Object {
      // A damaged file counts as no turbo; the next save rewrites it.
      return empty;
    }
  }

  void _write(TurboConfig global, Map<String, TurboConfig> games) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      jsonEncode({
        'global': _json(global),
        'games': {for (final e in games.entries) e.key: _json(e.value)},
      }),
    );
  }

  TurboConfig get global => _read().global;

  set global(TurboConfig c) {
    final r = _read();
    _write(c, r.games);
  }

  /// The game's own setup, else the global one.
  TurboConfig resolve(String sha1) {
    final r = _read();
    return r.games[sha1] ?? r.global;
  }

  bool hasGameOverride(String sha1) => _read().games.containsKey(sha1);

  void setGame(String sha1, TurboConfig c) {
    final r = _read();
    r.games[sha1] = c;
    _write(r.global, r.games);
  }

  /// Drops the game's setup so it follows the global one again.
  void clearGame(String sha1) {
    final r = _read();
    r.games.remove(sha1);
    _write(r.global, r.games);
  }
}

/// Button chips and a rate picker for one [TurboConfig].
class TurboEditor extends StatelessWidget {
  const TurboEditor({super.key, required this.value, required this.onChanged});

  final TurboConfig value;
  final ValueChanged<TurboConfig> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, bit) in turboButtons)
              FilterChip(
                label: Text(label),
                selected: value.mask & bit != 0,
                onSelected: (on) => onChanged((
                  mask: on ? value.mask | bit : value.mask & ~bit,
                  rate: value.rate,
                )),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: [
            for (final (rate, _) in turboRates)
              ButtonSegment(value: rate, label: Text('$rate/s')),
          ],
          showSelectedIcon: false,
          selected: {value.rate},
          onSelectionChanged: (s) =>
              onChanged((mask: value.mask, rate: s.first)),
        ),
      ],
    );
  }
}

TurboConfig _toggle(TurboConfig c, int bit) =>
    (mask: c.mask ^ bit, rate: c.rate);

/// Settings > Input > Turbo fire: the global setup as `TURBO.CFG`, one
/// `[ON]`/`[OFF]` row per button and the rate.
class TurboSettingsPage extends StatefulWidget {
  const TurboSettingsPage({super.key, required this.store});

  final TurboStore store;

  @override
  State<TurboSettingsPage> createState() => _TurboSettingsPageState();
}

class _TurboSettingsPageState extends State<TurboSettingsPage> {
  late TurboConfig value = widget.store.global;

  void _set(TurboConfig c) {
    setState(() => value = c);
    widget.store.global = c;
  }

  @override
  Widget build(BuildContext context) {
    return CfgPage(
      title: 'Turbo fire',
      path: const ['settings', 'input.cfg', 'turbo'],
      sections: [
        CfgTable(
          header: 'TURBO.CFG',
          rows: [
            for (final (i, (label, bit)) in turboButtons.indexed)
              CfgRow(
                label: 'Button $label',
                control: CfgToggle(
                  autofocus: i == 0,
                  value: value.mask & bit != 0,
                  semanticLabel: 'Turbo $label',
                  onChanged: (_) => _set(_toggle(value, bit)),
                ),
              ),
            CfgRow(
              label: 'Rate',
              control: CfgSegment<int>(
                values: [for (final (rate, _) in turboRates) rate],
                selected: value.rate,
                labelOf: (rate) => '$rate/s',
                onChanged: (rate) => _set((mask: value.mask, rate: rate)),
              ),
            ),
          ],
        ),
        LogLine(
          '> held turbo buttons repeat at the rate, on touch skins and '
          'controllers. games can override it from the pause menu.',
        ),
      ],
    );
  }
}

/// Short summary for list tiles: "A, B · 15/s" or "Off".
String turboSummary(TurboConfig c) {
  final names = [
    for (final (label, bit) in turboButtons)
      if (c.mask & bit != 0) label,
  ];
  return names.isEmpty ? 'Off' : '${names.join(', ')} · ${c.rate}/s';
}
