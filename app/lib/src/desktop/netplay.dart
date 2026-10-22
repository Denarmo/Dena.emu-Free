// SPDX-License-Identifier: GPL-3.0-or-later
// Netplay on Windows and SteamOS: two PCs play one game, on the same
// network or by joining a room on a relay server. Settings > NETPLAY.CFG and the pause menu's Netplay sheet.
// Spec: docs/specs/netplay.md
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/cfg_page.dart';
import '../shell/handheld.dart' show arrowsMoveFocus;
import '../shell/host_library.dart';
import '../shell/platform_features.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Systems whose games two PCs can play together (netplay.md, Systems).
const systemsWithNetplay = {
  'nes',
  'snes',
  'psx',
  'n64',
  'saturn',
  'dreamcast',
  'pico8',
};

const roomNeedsRelay = 'Set a relay server in Settings > NETPLAY.CFG first';

/// The room code alphabet (no 0/O/1/I), net_room.h.
const _codeLetters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// What the join field holds.
enum JoinKind { code, address, invalid }

/// Six letters and digits are a room code; anything with a dot or a colon
/// is an address (`host[:port]`); case does not matter for codes.
JoinKind joinKind(String text) {
  final s = text.trim();
  if (s.isEmpty || s.contains(' ')) return JoinKind.invalid;
  if (s.length == 6 && s.toUpperCase().split('').every(_codeLetters.contains)) {
    return JoinKind.code;
  }
  if (s.contains('.') || s.contains(':')) return JoinKind.address;
  return JoinKind.invalid;
}

/// The netplay choices, kept in `desktop_netplay.json` in the data folder.
class NetplaySettings extends ChangeNotifier {
  NetplaySettings({this.file, String relay = '', int delay = autoDelay})
    : _relay = relay.trim(),
      _delay = delay.clamp(autoDelay, maxDelay);

  /// Reads [file]; a missing or damaged file gives the defaults.
  factory NetplaySettings.load(File file) {
    var relay = '';
    var delay = autoDelay;
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map) {
          if (j['relay'] case final String r) relay = r;
          if (j['delay'] case final int d) delay = d;
        }
      }
    } on Object {
      // Defaults; the next change rewrites the file.
    }
    return NetplaySettings(file: file, relay: relay, delay: delay);
  }

  /// AUTO: 1 frame for rollback, half the round trip for lockstep.
  static const autoDelay = -1;
  static const maxDelay = 4;

  final File? file;
  String _relay;
  int _delay;

  /// The relay server, `host[:port]`; empty until the owner runs one.
  String get relay => _relay;

  /// Input delay in frames, [autoDelay] for AUTO.
  int get delay => _delay;

  set relay(String value) {
    final r = value.trim();
    if (r == _relay) return;
    _relay = r;
    _changed();
  }

  set delay(int value) {
    final d = value.clamp(autoDelay, maxDelay);
    if (d == _delay) return;
    _delay = d;
    _changed();
  }

  void _changed() {
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'relay': _relay, 'delay': _delay}));
    } on Object catch (e) {
      debugPrint('Netplay settings not saved: $e');
    }
  }
}

/// `LAN only`, or the relay server.
String netplaySummary(NetplaySettings s) =>
    s.relay.isEmpty ? 'LAN only' : s.relay;

/// Gives Settings and the pause menu the netplay choices; absent off the
/// desktop.
class NetplayScope extends InheritedNotifier<NetplaySettings> {
  const NetplayScope({
    super.key,
    required NetplaySettings settings,
    required super.child,
  }) : super(notifier: settings);

  static NetplaySettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NetplayScope>()?.notifier;
}

enum NetplayState { off, waiting, playing, ended }

/// `dena_netplay_info`, parsed.
class NetplayInfo {
  const NetplayInfo({
    this.state = NetplayState.off,
    this.host = false,
    this.slot = 0,
    this.method = 0,
    this.delay = 0,
    this.rttMs = 0,
    this.viaRelay = false,
    this.frame = 0,
    this.rollbackFrames = 0,
    this.stalls = 0,
    this.waiting = false,
    this.desyncs = 0,
    this.code = '',
    this.address = '',
    this.peer = '',
    this.error = '',
  });

  factory NetplayInfo.parse(String json) {
    try {
      final j = jsonDecode(json);
      if (j is! Map) return const NetplayInfo();
      int i(String k) => (j[k] as num?)?.toInt() ?? 0;
      String s(String k) => j[k] is String ? j[k] as String : '';
      return NetplayInfo(
        state: NetplayState.values[i('state').clamp(0, 3)],
        host: j['host'] == true,
        slot: i('slot'),
        method: i('method'),
        delay: i('delay'),
        rttMs: (j['rtt_ms'] as num?)?.toDouble() ?? 0,
        viaRelay: j['via_relay'] == true,
        frame: i('frame'),
        rollbackFrames: i('rollback_frames'),
        stalls: i('stalls'),
        waiting: j['waiting'] == true,
        desyncs: i('desyncs'),
        code: s('code'),
        address: s('address'),
        peer: s('peer'),
        error: s('error'),
      );
    } on Object {
      return const NetplayInfo();
    }
  }

  final NetplayState state;

  /// True on the hosting PC (player 1).
  final bool host;

  /// 0 for player 1, 1 for player 2.
  final int slot;

  /// 1 rollback, 2 lockstep, 0 before START.
  final int method;
  final int delay;
  final double rttMs;
  final bool viaRelay;
  final int frame;
  final int rollbackFrames;
  final int stalls;

  /// The other player has not sent input for a while (paused or slow).
  final bool waiting;
  final int desyncs;

  /// The room code while hosting a room.
  final String code;

  /// This PC's LAN address while hosting.
  final String address;
  final String peer;
  final String error;
}

/// The running game's netplay in the host library. Tests use a fake.
abstract interface class NetplayHost {
  /// Hosts on the LAN and, with [room], also a room on [relay].
  bool host({required String relay, required bool room, required int delay});

  /// Joins a room code (through [relay]) or an address.
  bool join(String target, {required String relay, required int delay});
  void stop();
  NetplayInfo get info;
}

/// Calls `dena_netplay_*` of dena_host.dll / libdena_host.so.
class FfiNetplayHost implements NetplayHost {
  FfiNetplayHost._(DynamicLibrary lib)
    : _host = lib
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>, Int32, Int32),
            int Function(int, Pointer<Utf8>, int, int)
          >('dena_netplay_host'),
      _join = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('dena_netplay_join'),
      _stop = lib.lookupFunction<Void Function(), void Function()>(
        'dena_netplay_stop',
      ),
      _info = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'dena_netplay_info',
          );

  final int Function(int, Pointer<Utf8>, int, int) _host;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, int) _join;
  final void Function() _stop;
  final Pointer<Utf8> Function() _info;

  static FfiNetplayHost? _instance;

  /// Null off the desktop or with a host library that predates netplay.
  static FfiNetplayHost? open() {
    if (_instance != null) return _instance;
    if (shellProfile != ShellProfile.desktop) return null;
    final lib = openHostLibrary();
    if (lib == null) return null;
    try {
      return _instance = FfiNetplayHost._(lib);
    } on ArgumentError {
      return null;
    }
  }

  @override
  bool host({required String relay, required bool room, required int delay}) =>
      using(
        (a) =>
            _host(0, relay.toNativeUtf8(allocator: a), room ? 1 : 0, delay) ==
            0,
      );

  @override
  bool join(String target, {required String relay, required int delay}) =>
      using(
        (a) =>
            _join(
              target.toNativeUtf8(allocator: a),
              relay.toNativeUtf8(allocator: a),
              delay,
            ) ==
            0,
      );

  @override
  void stop() => _stop();

  @override
  NetplayInfo get info => NetplayInfo.parse(_info().toDartString());
}

/// The pause menu's value: `[OFF]`, `[WAIT]`, `[P1]` or `[P2]`.
String netplayBadge(NetplayInfo i) => switch (i.state) {
  NetplayState.waiting => '[WAIT]',
  NetplayState.playing => '[P${i.slot + 1}]',
  _ => '[OFF]',
};

/// One-line status for the sheet.
String netplaySheetSummary(NetplayInfo i) => switch (i.state) {
  NetplayState.off => 'Not connected',
  NetplayState.waiting =>
    i.host ? 'Waiting for the other player' : 'Connecting…',
  NetplayState.playing when i.waiting => 'Waiting for the other player',
  NetplayState.playing =>
    'Playing as player ${i.slot + 1}'
        '${i.peer.isEmpty ? '' : ' with ${i.peer}'}',
  NetplayState.ended => 'Disconnected',
};

/// `DIRECT · 34 ms · rollback, delay 1`.
String netplayDetail(NetplayInfo i) => [
  i.viaRelay ? 'RELAY' : 'DIRECT',
  '${i.rttMs.round()} ms',
  switch (i.method) {
    1 => 'rollback, delay ${i.delay}',
    2 => 'lockstep, delay ${i.delay}',
    _ => 'starting',
  },
].join(' · ');

/// Host (LAN), Join by code or address, Disconnect.
class NetplaySheet extends StatefulWidget {
  const NetplaySheet({
    super.key,
    required this.netplay,
    required this.settings,
    this.poll = const Duration(milliseconds: 500),
  });

  final NetplayHost netplay;
  final NetplaySettings settings;
  final Duration poll;

  @override
  State<NetplaySheet> createState() => _NetplaySheetState();
}

class _NetplaySheetState extends State<NetplaySheet> {
  Timer? _timer;
  late NetplayInfo _info = widget.netplay.info;
  final _target = TextEditingController();

  /// Said under the buttons after a refused action.
  String? message;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.poll, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _target.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() => _info = widget.netplay.info);
  }

  NetplaySettings get settings => widget.settings;

  void _host() {
    message = widget.netplay.host(relay: '', room: false, delay: settings.delay)
        ? null
        : 'Start a game first';
    _refresh();
  }

  void _join() {
    final text = _target.text.trim();
    final kind = joinKind(text);
    if (kind == JoinKind.invalid) {
      setState(() => message = 'Type a room code (6 letters) or an address');
      return;
    }
    if (kind == JoinKind.code && settings.relay.isEmpty) {
      setState(() => message = roomNeedsRelay);
      return;
    }
    message =
        widget.netplay.join(
          kind == JoinKind.code ? text.toUpperCase() : text,
          relay: settings.relay,
          delay: settings.delay,
        )
        ? null
        : 'Start a game first';
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final i = _info;
    final busy =
        i.state == NetplayState.waiting || i.state == NetplayState.playing;
    final details = <String>[
      if (i.state == NetplayState.ended && i.error.isNotEmpty) i.error,
      if (i.state == NetplayState.waiting && i.host && i.address.isNotEmpty)
        'This PC: ${i.address}',
      if (i.state == NetplayState.playing) netplayDetail(i),
      if (i.state == NetplayState.playing && i.desyncs > 0)
        'Fixed ${i.desyncs} desync${i.desyncs == 1 ? '' : 's'}',
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        BrutalTokens.s3,
        BrutalTokens.s3,
        BrutalTokens.s3 + 6,
        BrutalTokens.s4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Play this game with another PC running Dena.emu. Open the same '
            'game on both, host on one and join from the other. The host is '
            'player 1.',
            style: t.body.copyWith(color: t.mutedText),
          ),
          const SizedBox(height: BrutalTokens.s3),
          BrutalPanel(
            header: 'STATUS',
            padding: const EdgeInsets.all(BrutalTokens.s3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LogLine(
                  netplaySheetSummary(i),
                  status: switch (i.state) {
                    NetplayState.playing when !i.waiting => LogStatus.ok,
                    NetplayState.ended => LogStatus.err,
                    _ => LogStatus.none,
                  },
                ),
                for (final d in details) ...[
                  const SizedBox(height: BrutalTokens.s1),
                  Text(d, style: t.small.copyWith(color: t.mutedText)),
                ],
                if (i.code.isNotEmpty && busy) ...[
                  const SizedBox(height: BrutalTokens.s2),
                  Text('ROOM CODE', style: t.label),
                  Text(i.code, style: t.display),
                ],
              ],
            ),
          ),
          const SizedBox(height: BrutalTokens.s4),
          if (busy)
            BrutalButton(
              autofocus: true,
              expand: true,
              icon: DenaIcons.linkOff,
              label: i.state == NetplayState.playing ? 'Disconnect' : 'Cancel',
              onPressed: () {
                widget.netplay.stop();
                _refresh();
              },
            )
          else ...[
            BrutalButton(
              autofocus: true,
              expand: true,
              variant: BrutalButtonVariant.primary,
              icon: DenaIcons.broadcast,
              label: 'Host',
              value: 'LAN',
              onPressed: _host,
            ),
            const SizedBox(height: BrutalTokens.s4),
            Text('Join by room code or address', style: t.label),
            const SizedBox(height: BrutalTokens.s1),
            Row(
              children: [
                Expanded(
                  child: CommandField(
                    controller: _target,
                    hint: 'K7P2QX or 192.168.1.20',
                    onSubmitted: (_) => _join(),
                  ),
                ),
                const SizedBox(width: BrutalTokens.s2),
                BrutalButton(label: 'Join', onPressed: _join),
              ],
            ),
          ],
          if (message case final m?) ...[
            const SizedBox(height: BrutalTokens.s3),
            LogLine(m, status: LogStatus.err),
          ],
        ],
      ),
    );
  }
}

/// The `NETPLAY ....... LAN ONLY >` row of the settings.
class NetplayTile extends StatelessWidget {
  const NetplayTile({super.key, required this.settings});

  final NetplaySettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => CfgRow(
      label: 'Netplay',
      value: netplaySummary(settings),
      onOpen: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NetplayPage(settings: settings),
        ),
      ),
    ),
  );
}

/// Input delay (AUTO 0 1 2 3 4), the relay server and how to play explained.
class NetplayPage extends StatefulWidget {
  const NetplayPage({super.key, required this.settings});

  final NetplaySettings settings;

  @override
  State<NetplayPage> createState() => _NetplayPageState();
}

class _NetplayPageState extends State<NetplayPage> {
  late final _relay = TextEditingController(text: widget.settings.relay);

  static const _delays = [NetplaySettings.autoDelay, 0, 1, 2, 3, 4];

  @override
  void dispose() {
    // Kept as typed, also without Enter.
    widget.settings.relay = _relay.text;
    _relay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Shortcuts(
        shortcuts: arrowsMoveFocus,
        child: CfgPage(
          title: 'Netplay',
          path: const ['settings', 'netplay.cfg', 'netplay'],
          sections: [
            CfgTable(
              header: 'NETPLAY.CFG',
              rows: [
                CfgRow(
                  label: 'Input delay',
                  // The D-pad starts on the delay choices.
                  control: AutofocusFirst(
                    child: CfgSegment<int>(
                      values: _delays,
                      selected: settings.delay,
                      labelOf: (d) => d < 0 ? 'Auto' : '$d',
                      onChanged: (d) => settings.delay = d,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: BrutalTokens.s3,
                    vertical: BrutalTokens.s2,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'RELAY SERVER',
                        style: BrutalTokens.of(context).label,
                      ),
                      const SizedBox(height: BrutalTokens.s1),
                      CommandField(
                        controller: _relay,
                        hint: 'relay.example.net:47340',
                        onChanged: (v) => settings.relay = v,
                        onSubmitted: (v) => settings.relay = v,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const LogLine(
              'Play on the same network (Host shows this PC\'s address), '
              'join a room on a relay server by its code, or join an '
              'address whose port 47330 is forwarded. No relay server comes '
              'with the app: enter one here.',
            ),
            const LogLine(
              'Input delay AUTO is 1 frame for NES, SNES and PICO-8 '
              '(rollback) and half the ping for PS1, N64, Saturn and '
              'Dreamcast (lockstep). More delay means fewer corrections.',
            ),
          ],
        ),
      ),
    );
  }
}
