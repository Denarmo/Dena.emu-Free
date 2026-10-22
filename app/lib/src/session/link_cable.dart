// SPDX-License-Identifier: GPL-3.0-or-later
// Link cable over Wi-Fi for Game Boy, Game Boy Color and Game Boy Advance:
// the native transport (host/src/link.c) and the pause-menu sheet.
// Spec: docs/specs/link-cable.md
import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:material_ui/material_ui.dart';

import '../desktop/netplay.dart';
import '../shell/host_library.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Systems whose core speaks the link cable.
const systemsWithLink = {'gb', 'gbc', 'gba'};

enum LinkState { off, waiting, connected, failed }

/// A host the scan heard.
typedef LinkHost = ({String name, String address, int port});

/// The native link (one per process). Tests use a fake.
abstract interface class LinkCable {
  bool host(String name);
  bool join(String address, {int port = 0});
  void stop();
  LinkState get state;

  /// True when this device hosts (the first player, GBA parent).
  bool get hosting;
  String get error;
  String get peer;
  String get localAddress;
  bool startScan();
  void stopScan();
  List<LinkHost> get hosts;
}

/// Rooms over the internet (netplay.md, Link cable over the internet); the
/// desktop's native link has them.
abstract interface class LinkRooms {
  /// Joins a room code (through [relay]) or an address.
  bool joinRoom(String target, String relay);

  /// The room code while hosting a room, else empty.
  String get roomCode;

  /// True while the link goes through the relay.
  bool get viaRelay;
}

/// Parses `name\taddress\tport\n` lines from `dena_link_scan_results`.
List<LinkHost> parseHosts(String text) => [
  for (final line in text.split('\n'))
    if (line.split('\t') case [final name, final address, final port])
      if (int.tryParse(port) case final p?)
        (name: name, address: address, port: p),
];

/// Calls the `dena_link_*` functions in the native library over dart:ffi.
class FfiLinkCable implements LinkCable, LinkRooms {
  FfiLinkCable._(DynamicLibrary lib)
    : _host = lib
          .lookupFunction<
            Int32 Function(Int32, Pointer<Utf8>),
            int Function(int, Pointer<Utf8>)
          >('dena_link_host'),
      _join = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('dena_link_join'),
      _stop = lib.lookupFunction<Void Function(), void Function()>(
        'dena_link_stop',
      ),
      _state = lib.lookupFunction<Int32 Function(), int Function()>(
        'dena_link_state',
      ),
      _role = lib.lookupFunction<Int32 Function(), int Function()>(
        'dena_link_role',
      ),
      _error = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'dena_link_error',
          ),
      _peer = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'dena_link_peer',
          ),
      _scanStart = lib.lookupFunction<Int32 Function(), int Function()>(
        'dena_link_scan_start',
      ),
      _scanStop = lib.lookupFunction<Void Function(), void Function()>(
        'dena_link_scan_stop',
      ),
      _scanResults = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('dena_link_scan_results'),
      _local = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('dena_link_local_address'),
      _joinRoom = _optional(
        () =>
            lib.lookupFunction<
              Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
              int Function(Pointer<Utf8>, Pointer<Utf8>)
            >('dena_link_join_room'),
      ),
      _roomCode = _optional(
        () => lib
            .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
              'dena_link_room_code',
            ),
      ),
      _viaRelay = _optional(
        () => lib.lookupFunction<Int32 Function(), int Function()>(
          'dena_link_via_relay',
        ),
      );

  /// Null for a host library built before rooms (phones keep LAN only).
  static T? _optional<T>(T Function() lookup) {
    try {
      return lookup();
    } on ArgumentError {
      return null;
    }
  }

  final int Function(int, Pointer<Utf8>) _host;
  final int Function(Pointer<Utf8>, int) _join;
  final void Function() _stop;
  final int Function() _state;
  final int Function() _role;
  final Pointer<Utf8> Function() _error;
  final Pointer<Utf8> Function() _peer;
  final int Function() _scanStart;
  final void Function() _scanStop;
  final int Function(Pointer<Utf8>, int) _scanResults;
  final int Function(Pointer<Utf8>, int) _local;
  final int Function(Pointer<Utf8>, Pointer<Utf8>)? _joinRoom;
  final Pointer<Utf8> Function()? _roomCode;
  final int Function()? _viaRelay;

  static FfiLinkCable? _instance;

  /// Null where the native library is not available (desktop, tests).
  static FfiLinkCable? open() {
    if (_instance != null) return _instance;
    try {
      final DynamicLibrary lib;
      final host = openHostLibrary();
      if (host == null) return null;
      lib = host;
      return _instance = FfiLinkCable._(lib);
    } on ArgumentError {
      return null;
    }
  }

  @override
  bool host(String name) =>
      using((a) => _host(0, name.toNativeUtf8(allocator: a)) == 0);

  @override
  bool join(String address, {int port = 0}) =>
      using((a) => _join(address.toNativeUtf8(allocator: a), port) == 0);

  @override
  void stop() => _stop();

  @override
  LinkState get state => LinkState.values[_state().clamp(0, 3)];

  @override
  bool get hosting => _role() == 0;

  @override
  String get error => _error().toDartString();

  @override
  String get peer => _peer().toDartString();

  String _read(int Function(Pointer<Utf8>, int) fn, int size) => using((a) {
    final buf = a<Uint8>(size).cast<Utf8>();
    fn(buf, size);
    return buf.toDartString();
  });

  @override
  String get localAddress => _read(_local, 64);

  @override
  bool startScan() => _scanStart() == 0;

  @override
  void stopScan() => _scanStop();

  @override
  List<LinkHost> get hosts => parseHosts(_read(_scanResults, 2048));

  @override
  bool joinRoom(String target, String relay) => using(
    (a) =>
        _joinRoom?.call(
          target.toNativeUtf8(allocator: a),
          relay.toNativeUtf8(allocator: a),
        ) ==
        0,
  );

  @override
  String get roomCode => _roomCode?.call().toDartString() ?? '';

  @override
  bool get viaRelay => (_viaRelay?.call() ?? 0) != 0;
}

/// One-line status for the pause sheet.
String linkSummary(LinkCable link) => switch (link.state) {
  LinkState.off => 'Not connected',
  LinkState.waiting =>
    link.hosting ? 'Waiting for another device' : 'Connecting…',
  LinkState.connected => 'Connected to ${link.peer}',
  LinkState.failed => 'Disconnected',
};

/// Host, find or join a link. Both devices must be on the same Wi-Fi.
class LinkCableSheet extends StatefulWidget {
  const LinkCableSheet({
    super.key,
    required this.link,
    required this.gameTitle,
    this.internet,
    this.poll = const Duration(milliseconds: 500),
  });

  final LinkCable link;
  final String gameTitle;

  /// The desktop's netplay settings: adds room codes when the
  /// link has [LinkRooms] (netplay.md); null keeps the LAN sheet.
  final NetplaySettings? internet;
  final Duration poll;

  @override
  State<LinkCableSheet> createState() => _LinkCableSheetState();
}

class _LinkCableSheetState extends State<LinkCableSheet> {
  Timer? _timer;
  List<LinkHost> _hosts = const [];
  final _address = TextEditingController();

  /// Said under the join field after a refused action.
  String? message;

  LinkCable get link => widget.link;

  /// Rooms, on the desktop only.
  LinkRooms? get rooms => switch (link) {
    final LinkRooms r when widget.internet != null => r,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    if (link.state != LinkState.connected) link.startScan();
    _timer = Timer.periodic(widget.poll, (_) => _refresh());
    _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _hosts = link.state == LinkState.connected ? const [] : link.hosts;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    link.stopScan();
    _address.dispose();
    super.dispose();
  }

  void _join(String address, int port) {
    message = null;
    link.join(address, port: port);
    _refresh();
  }

  /// The join field: a room code on the desktop, else an address.
  void _joinTyped(String text) {
    final r = rooms;
    final relay = widget.internet?.relay ?? '';
    if (r == null) return _join(text, 0);
    switch (joinKind(text)) {
      case JoinKind.invalid:
        setState(() => message = 'Type a room code (6 letters) or an address');
      case JoinKind.code when relay.isEmpty:
        setState(() => message = roomNeedsRelay);
      case JoinKind.code:
        message = null;
        r.joinRoom(text.toUpperCase(), relay);
        _refresh();
      case JoinKind.address:
        message = null;
        r.joinRoom(text, '');
        _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final state = link.state;
    final busy = state == LinkState.waiting || state == LinkState.connected;
    final local = link.localAddress;
    final code = rooms?.roomCode ?? '';
    final detail = switch (state) {
      LinkState.failed when link.error.isNotEmpty => link.error,
      LinkState.waiting when link.hosting && local.isNotEmpty =>
        'This device: $local',
      LinkState.connected when rooms != null =>
        rooms!.viaRelay ? 'RELAY' : 'DIRECT',
      _ => null,
    };
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
            'Trade and battle with another device running Dena.emu on the '
            'same Wi-Fi. Open the game on both, host on one and join from '
            'the other.',
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
                  linkSummary(link),
                  status: switch (state) {
                    LinkState.connected => LogStatus.ok,
                    LinkState.failed => LogStatus.err,
                    _ => LogStatus.none,
                  },
                ),
                if (detail != null) ...[
                  const SizedBox(height: BrutalTokens.s1),
                  Text(detail, style: t.small.copyWith(color: t.mutedText)),
                ],
                if (code.isNotEmpty && busy) ...[
                  const SizedBox(height: BrutalTokens.s2),
                  Text('ROOM CODE', style: t.label),
                  Text(code, style: t.display),
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
              label: state == LinkState.connected ? 'Disconnect' : 'Cancel',
              onPressed: () {
                link.stop();
                link.startScan();
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
              onPressed: () {
                link.stopScan();
                link.host(widget.gameTitle);
                _refresh();
              },
            ),
            const SizedBox(height: BrutalTokens.s4),
            Text('Devices nearby', style: t.label),
            const SizedBox(height: BrutalTokens.s1),
            if (_hosts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: BrutalTokens.s2),
                child: LogLine('Looking for a device that is hosting…'),
              )
            else
              Padding(
                padding: EdgeInsets.only(
                  right: t.shadowOffsetLarge.dx,
                  bottom: t.shadowOffsetLarge.dy,
                ),
                child: BrutalTable(
                  shrinkWrap: true,
                  columns: const [
                    BrutalColumn('Device', flex: 3),
                    BrutalColumn('Address', flex: 2),
                  ],
                  rowCount: _hosts.length,
                  onRowPressed: (i) => _join(_hosts[i].address, _hosts[i].port),
                  cellBuilder: (context, row, column, lit) => Text(
                    column == 0 ? _hosts[row].name : _hosts[row].address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            const SizedBox(height: BrutalTokens.s4),
            Text(
              rooms == null
                  ? 'Join by address'
                  : 'Join by room code or address',
              style: t.label,
            ),
            const SizedBox(height: BrutalTokens.s1),
            Row(
              children: [
                Expanded(
                  child: CommandField(
                    controller: _address,
                    hint: rooms == null
                        ? '192.168.1.20'
                        : 'K7P2QX or 192.168.1.20',
                    onSubmitted: (v) => _joinTyped(v.trim()),
                  ),
                ),
                const SizedBox(width: BrutalTokens.s2),
                BrutalButton(
                  label: 'Join',
                  onPressed: () => _joinTyped(_address.text.trim()),
                ),
              ],
            ),
            if (message case final m?) ...[
              const SizedBox(height: BrutalTokens.s3),
              LogLine(m, status: LogStatus.err),
            ],
          ],
        ],
      ),
    );
  }
}
