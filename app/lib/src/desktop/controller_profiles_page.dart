// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Input > Controller profiles (Windows and SteamOS): the
// connected pads, the saved profiles and the editor for one profile
// (controller, game, gyro, button remap).
// Spec: docs/specs/gamepads.md (Desktop: profiles and gyro)
import 'package:material_ui/material_ui.dart';

import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import '../ui/brutal/brutal.dart';
import 'controller_profiles.dart';

/// A game a profile can be for: its SHA-1 and title.
typedef ProfileGame = ({String sha1, String title});

/// Loads the library's games for the editor's game choice.
typedef ProfileGames = Future<List<ProfileGame>> Function();

/// Gives Settings and the game screen the profiles; absent off the desktop.
class ControllerProfilesScope
    extends InheritedNotifier<ControllerProfileStore> {
  const ControllerProfilesScope({
    super.key,
    required ControllerProfileStore store,
    required super.child,
  }) : super(notifier: store);

  static ControllerProfileStore? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ControllerProfilesScope>()
      ?.notifier;
}

/// `3 saved`, or `none`.
String profilesSummary(ControllerProfileStore s) =>
    s.profiles.isEmpty ? 'none' : '${s.profiles.length} saved';

String _controllerLabel(ControllerProfile p) => p.anyController
    ? 'Any controller'
    : (p.controllerName.isEmpty ? p.controller : p.controllerName);

String _gameLabel(ControllerProfile p) => p.anyGame
    ? 'Any game'
    : (p.gameTitle.isEmpty ? p.game.substring(0, 8) : p.gameTitle);

String _gyroLabel(ControllerProfile p) =>
    p.gyro == GyroMode.off ? 'off' : '${p.gyro.label} x${_num(p.sensitivity)}';

String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// The `PROFILES ....... 2 SAVED >` row of the settings.
class ControllerProfilesTile extends StatelessWidget {
  const ControllerProfilesTile({super.key, required this.store, this.games});

  final ControllerProfileStore store;
  final ProfileGames? games;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) => CfgRow(
      label: 'Profiles',
      value: profilesSummary(store),
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ControllerProfilesPage(store: store, games: games),
        ),
      ),
    ),
  );
}

/// Connected controllers (port, name, gyro) and the saved profiles.
class ControllerProfilesPage extends StatelessWidget {
  const ControllerProfilesPage({super.key, required this.store, this.games});

  final ControllerProfileStore store;
  final ProfileGames? games;

  void _edit(BuildContext context, ControllerProfile p) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ControllerProfileEditor(store: store, profile: p, games: games),
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final pads = store.pads();
      final profiles = [...store.profiles]
        ..sort((a, b) {
          final g = _gameLabel(a).compareTo(_gameLabel(b));
          return g != 0
              ? g
              : _controllerLabel(a).compareTo(_controllerLabel(b));
        });
      return Shortcuts(
        shortcuts: arrowsMoveFocus,
        child: CfgPage(
          title: 'Controller profiles',
          path: const ['settings', 'input.cfg', 'profiles'],
          sections: [
            CfgTable(
              header: 'PROFILES.CFG',
              rows: [
                CfgRow(
                  label: 'New profile',
                  value: 'any controller · any game',
                  autofocus: true,
                  onOpen: () => _edit(context, const ControllerProfile()),
                ),
              ],
            ),
            BrutalPanel(
              header: 'SAVED',
              child: profiles.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(BrutalTokens.s3),
                      child: LogLine('No profiles yet: every pad plays as is.'),
                    )
                  : BrutalTable(
                      shrinkWrap: true,
                      columns: const [
                        BrutalColumn('Controller', flex: 3),
                        BrutalColumn('Game', flex: 3),
                        BrutalColumn('Remap', width: 80),
                        BrutalColumn('Gyro', width: 132),
                      ],
                      rowCount: profiles.length,
                      onRowPressed: (i) => _edit(context, profiles[i]),
                      cellBuilder: (context, row, column, lit) {
                        final p = profiles[row];
                        return Text(
                          switch (column) {
                            0 => _controllerLabel(p),
                            1 => _gameLabel(p),
                            2 => p.remapped == 0 ? '--' : '${p.remapped}',
                            _ => _gyroLabel(p),
                          },
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
            ),
            BrutalPanel(
              header: 'CONNECTED',
              child: pads.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(BrutalTokens.s3),
                      child: LogLine('No controllers connected.'),
                    )
                  : BrutalTable(
                      shrinkWrap: true,
                      columns: const [
                        BrutalColumn('P', width: 44),
                        BrutalColumn('Controller', flex: 1),
                        BrutalColumn('Gyro', width: 72),
                      ],
                      rowCount: pads.length,
                      cellBuilder: (context, row, column, lit) {
                        final pad = pads[row];
                        return Text(
                          switch (column) {
                            0 => pad.port < 0 ? '--' : '${pad.port + 1}',
                            1 => pad.name,
                            _ => pad.gyro ? 'yes' : '--',
                          },
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
            ),
            const LogLine(
              'A game\'s profile beats a controller\'s: this controller in '
              'this game, then any controller in this game, then this '
              'controller in any game, then any controller in any game. Up '
              'to 8 players: with 3 or more pads, games that take a '
              'multitap get one. Gyro '
              'needs a Steam Deck, DualSense, DualShock 4 or Switch Pro '
              'connected directly: under Steam Input, turn Steam Input off '
              'for Dena.emu to use it here.',
            ),
          ],
        ),
      );
    },
  );
}

/// Buttons in the order the remap table lists them.
const _remapOrder = [8, 0, 9, 1, 10, 11, 12, 13, 14, 15, 3, 2, 4, 5, 6, 7];

/// One profile; every change is saved at once.
class ControllerProfileEditor extends StatefulWidget {
  const ControllerProfileEditor({
    super.key,
    required this.store,
    required this.profile,
    this.games,
  });

  final ControllerProfileStore store;
  final ControllerProfile profile;
  final ProfileGames? games;

  @override
  State<ControllerProfileEditor> createState() =>
      _ControllerProfileEditorState();
}

class _ControllerProfileEditorState extends State<ControllerProfileEditor> {
  late ControllerProfile _p = widget.profile;

  Future<void> _set(ControllerProfile next) async {
    setState(() => _p = next);
    final saved = await widget.store.save(next);
    if (mounted) setState(() => _p = saved);
  }

  Future<T?> _choose<T>({
    required String title,
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
  }) => Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (_) => ProfileChoicePage<T>(
        title: title,
        values: values,
        selected: selected,
        labelOf: labelOf,
      ),
    ),
  );

  Future<void> _pickController() async {
    final pads = widget.store.pads();
    final seen = <String>{};
    final choices = <(String, String)>[
      ('', 'Any controller'),
      for (final pad in pads)
        if (seen.add(pad.guid)) (pad.guid, pad.name),
      if (!_p.anyController && !seen.contains(_p.controller))
        (_p.controller, _controllerLabel(_p)),
    ];
    final c = await _choose<(String, String)>(
      title: 'Controller',
      values: choices,
      selected: choices.firstWhere(
        (c) => c.$1 == _p.controller,
        orElse: () => choices.first,
      ),
      labelOf: (c) => c.$2,
    );
    if (c != null && c.$1 != _p.controller) {
      await _set(
        _p.copyWith(controller: c.$1, controllerName: c.$1.isEmpty ? '' : c.$2),
      );
    }
  }

  Future<void> _pickGame() async {
    final games = await widget.games?.call() ?? const <ProfileGame>[];
    if (!mounted) return;
    final choices = <ProfileGame>[
      (sha1: '', title: 'Any game'),
      ...[...games]..sort((a, b) => a.title.compareTo(b.title)),
    ];
    final g = await _choose<ProfileGame>(
      title: 'Game',
      values: choices,
      selected: choices.firstWhere(
        (g) => g.sha1 == _p.game,
        orElse: () => choices.first,
      ),
      labelOf: (g) => g.title,
    );
    if (g != null && g.sha1 != _p.game) {
      await _set(
        _p.copyWith(game: g.sha1, gameTitle: g.sha1.isEmpty ? '' : g.title),
      );
    }
  }

  Future<void> _pickTarget(int source) async {
    final targets = [-1, ..._remapOrder];
    final t = await _choose<int>(
      title: 'Sends ${retroPadButtons[source]}',
      values: targets,
      selected: _p.buttons[source],
      labelOf: (b) => b < 0 ? 'Nothing' : retroPadButtons[b],
    );
    if (t != null && t != _p.buttons[source]) {
      await _set(_p.copyWith(buttons: [..._p.buttons]..[source] = t));
    }
  }

  @override
  Widget build(BuildContext context) {
    final gyroOn = _p.gyro != GyroMode.off;
    return Shortcuts(
      shortcuts: arrowsMoveFocus,
      child: CfgPage(
        title: 'Profile',
        path: const ['settings', 'input.cfg', 'profiles', 'edit'],
        sections: [
          CfgTable(
            header: 'PROFILE.CFG',
            rows: [
              CfgRow(
                label: 'Controller',
                value: _controllerLabel(_p),
                autofocus: true,
                onOpen: _pickController,
              ),
              CfgRow(label: 'Game', value: _gameLabel(_p), onOpen: _pickGame),
              if (_p.id != null)
                Padding(
                  padding: const EdgeInsets.all(BrutalTokens.s2),
                  child: HoldToConfirm(
                    label: 'HOLD TO DELETE',
                    expand: true,
                    onConfirmed: () async {
                      final nav = Navigator.of(context);
                      await widget.store.remove(_p);
                      nav.pop();
                    },
                  ),
                ),
            ],
          ),
          CfgTable(
            header: 'GYRO.CFG',
            rows: [
              CfgRow(
                label: 'Gyro',
                control: CfgSegment<GyroMode>(
                  values: GyroMode.values,
                  selected: _p.gyro,
                  labelOf: (m) => m.label,
                  onChanged: (m) => _set(_p.copyWith(gyro: m)),
                ),
              ),
              CfgRow(
                label: 'Sensitivity',
                control: CfgSegment<double>(
                  values: gyroSensitivities,
                  selected: _p.sensitivity,
                  labelOf: (v) => 'x${_num(v)}',
                  onChanged: gyroOn
                      ? (v) => _set(_p.copyWith(sensitivity: v))
                      : null,
                ),
              ),
              CfgRow(
                label: 'Dead zone',
                control: CfgSegment<double>(
                  values: gyroDeadzones,
                  selected: _p.deadzone,
                  labelOf: (v) => '${_num(v)}°/s',
                  onChanged: gyroOn
                      ? (v) => _set(_p.copyWith(deadzone: v))
                      : null,
                ),
              ),
              CfgRow(
                label: 'Invert Y',
                control: CfgToggle(
                  value: _p.invertY,
                  onChanged: gyroOn
                      ? (v) => _set(_p.copyWith(invertY: v))
                      : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(BrutalTokens.s2),
                child: LogLine('${_p.gyro.description}.'),
              ),
            ],
          ),
          BrutalPanel(
            header: 'BUTTONS.CFG',
            child: BrutalTable(
              shrinkWrap: true,
              columns: const [
                BrutalColumn('Button', flex: 1),
                BrutalColumn('Sends', flex: 1),
              ],
              rowCount: _remapOrder.length,
              onRowPressed: (i) => _pickTarget(_remapOrder[i]),
              cellBuilder: (context, row, column, lit) {
                final source = _remapOrder[row];
                final target = _p.buttons[source];
                return Text(switch (column) {
                  0 => retroPadButtons[source].toUpperCase(),
                  _ when target == source => '= ${retroPadButtons[source]}',
                  _ when target < 0 => 'NOTHING',
                  _ => '-> ${retroPadButtons[target].toUpperCase()}',
                });
              },
            ),
          ),
          if (_p.remapped > 0)
            BrutalButton(
              label: 'Reset buttons',
              onPressed: () => _set(_p.copyWith(buttons: identityButtons)),
            ),
        ],
      ),
    );
  }
}

/// A list to pick one of [values]; pops with the choice.
class ProfileChoicePage<T> extends StatelessWidget {
  const ProfileChoicePage({
    super.key,
    required this.title,
    required this.values,
    required this.selected,
    required this.labelOf,
  });

  final String title;
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    final at = values.indexOf(selected);
    return Shortcuts(
      shortcuts: arrowsMoveFocus,
      child: CfgPage(
        title: title,
        path: ['settings', 'input.cfg', 'profiles', title.toLowerCase()],
        sections: [
          BrutalPanel(
            header: title.toUpperCase(),
            child: BrutalTable(
              shrinkWrap: true,
              columns: const [
                BrutalColumn('', width: 44),
                BrutalColumn('Choice', flex: 1),
              ],
              rowCount: values.length,
              selectedRow: at < 0 ? null : at,
              autofocusRow: at < 0 ? 0 : at,
              onRowPressed: (i) => Navigator.of(context).pop(values[i]),
              cellBuilder: (context, row, column, lit) => Text(
                column == 0
                    ? (row == at ? '[x]' : '[ ]')
                    : labelOf(values[row]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
