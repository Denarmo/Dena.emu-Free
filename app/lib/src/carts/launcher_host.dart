// SPDX-License-Identifier: GPL-3.0-or-later
// The app side of the Dena Explore launcher cart's host API: a request /
// reply mailbox in the PICO-8 GPIO bytes. Spec: docs/specs/pico8-launcher-cart.md
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../library/database.dart';
import '../library/importer.dart';
import '../shell/host_library.dart';
import 'bbs.dart';
import 'cart_download.dart';

/// PICO-8 address of the GPIO bytes, and their count.
const gpioAddress = 0x5f80;
const gpioSize = 128;

/// Payload bytes per mailbox message (bytes 8–127).
const payloadMax = 120;

/// Most library carts sent in one list.
const maxLocalCarts = 200;

/// Mailbox states (byte 0; 0 is idle).
const _request = 1, _working = 2, _replyReady = 3;

/// Commands (byte 1).
const cmdHello = 1,
    cmdLocal = 2,
    cmdBbs = 3,
    cmdGet = 4,
    cmdRun = 5,
    cmdFav = 6,
    cmdMore = 7;

/// The GPIO window of the running PICO-8 session.
abstract interface class GpioPort {
  /// The GPIO bytes after the last frame, or null before there are any.
  Uint8List? read();

  /// Writes [bytes] at [offset] in the GPIO window before the next frame.
  /// Writes go in in call order.
  void write(int offset, List<int> bytes);
}

/// [GpioPort] over the runner's RAM mailbox (`dena_ram_*`, dart:ffi): in
/// `libdena_android.so` on Android, in the launcher process on Linux.
class FfiGpioPort implements GpioPort {
  FfiGpioPort._(this._buffer, this._read, this._write);

  /// The shell's transfer buffer (256 bytes).
  final Uint8List _buffer;
  final int Function(int) _read;
  final void Function(int, int) _write;

  /// Starts watching the GPIO window; null where the shell has no mailbox
  /// (desktop, tests).
  static FfiGpioPort? open() {
    final DynamicLibrary lib;
    try {
      final host = openHostLibrary();
      if (host == null) return null;
      lib = host;
      final watch = lib
          .lookupFunction<Void Function(Int32, Int32), void Function(int, int)>(
            'dena_ram_watch',
          );
      final buffer = lib
          .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
            'dena_ram_buffer',
          );
      final read = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'dena_ram_read',
      );
      final write = lib
          .lookupFunction<Void Function(Int32, Int32), void Function(int, int)>(
            'dena_ram_write',
          );
      watch(gpioAddress, gpioSize);
      return FfiGpioPort._(buffer().asTypedList(256), read, write);
    } on ArgumentError {
      return null;
    }
  }

  @override
  Uint8List? read() => _read(gpioSize) == 1
      ? Uint8List.fromList(_buffer.sublist(0, gpioSize))
      : null;

  @override
  void write(int offset, List<int> bytes) {
    _buffer.setRange(0, bytes.length, bytes);
    _write(gpioAddress + offset, bytes.length);
  }
}

/// Answers the launcher cart's requests. One per launcher session.
class LauncherHost {
  LauncherHost({
    required this.port,
    required this.db,
    required this.importer,
    required this.credits,
    required this.onRun,
    this.client,
    this.hasNetwork = deviceHasNetwork,
  });

  final GpioPort port;
  final LibraryDatabase db;
  final Importer importer;
  final CartCredits credits;

  /// Null when browsing the BBS is off: the cart lists library carts only.
  final BbsClient? client;

  /// Whether the device has a network connection at all; when it has none,
  /// BBS requests say so instead of failing at the BBS.
  final Future<bool> Function() hasNetwork;

  /// The cart asked to play [game]; the session should end and play it.
  final void Function(Game game) onRun;

  int _lastSeq = 0;
  bool _busy = false;
  String _reply = '';
  bool _replyError = false;
  final _bbs = <BbsCart>[];
  Timer? _timer;

  /// Polls the mailbox every 16 ms until [stop].
  void start() {
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => unawaited(poll()),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Handles a new request, if there is one; completes once its reply is
  /// written. Requests that arrive while one is in progress wait.
  Future<void> poll() async {
    if (_busy) return;
    final g = port.read();
    if (g == null || g.length < gpioSize) return;
    final seq = g[5];
    if (g[0] != _request || seq == 0 || seq == _lastSeq) return;
    _lastSeq = seq;
    final cmd = g[1], chunk = g[2];
    final arg = String.fromCharCodes(
      g.sublist(8, 8 + math.min(g[3], payloadMax)),
    );
    if (cmd == cmdMore) {
      _sendChunk(cmd, chunk, seq);
      return;
    }
    _busy = true;
    port.write(0, [_working]);
    try {
      final (text, error) = await _handle(cmd, arg);
      _reply = cartText(text);
      _replyError = error;
    } on Object catch (e) {
      _reply = cartText(e is BbsException ? e.message : 'something went wrong');
      _replyError = true;
    } finally {
      _busy = false;
    }
    _sendChunk(cmd, 0, seq);
  }

  void _sendChunk(int cmd, int chunk, int seq) {
    final start = math.min(chunk * payloadMax, _reply.length);
    final end = math.min(start + payloadMax, _reply.length);
    final more = end < _reply.length;
    final payload = _reply.substring(start, end).codeUnits;
    port.write(0, [
      _replyReady,
      cmd,
      chunk,
      payload.length,
      (more ? 1 : 0) | (_replyError ? 2 : 0),
      seq,
      0,
      0,
      ...payload,
    ]);
  }

  Future<(String, bool)> _handle(int cmd, String arg) async {
    switch (cmd) {
      case cmdHello:
        return (client != null ? '1' : '0', false);
      case cmdLocal:
        return (await _local(favouritesOnly: arg == 'fav'), false);
      case cmdBbs:
        if (client == null) return ('offline', true);
        if (!await hasNetwork()) return (noNetworkMessage, true);
        return _bbsList(arg);
      case cmdGet:
        if (client == null) return ('offline', true);
        if (!await hasNetwork()) return (noNetworkMessage, true);
        return _get(arg);
      case cmdRun:
        final game = await _game(arg);
        if (game == null) return ('not in your library', true);
        onRun(game);
        return ('ok', false);
      case cmdFav:
        final game = await _game(arg);
        if (game == null) return ('not in your library', true);
        await db.setFavorite(game.id, !game.favorite);
        return (game.favorite ? '0' : '1', false);
      default:
        return ('unknown command', true);
    }
  }

  Future<Game?> _game(String arg) async {
    final id = int.tryParse(arg.trim());
    if (id == null) return null;
    final game = await db.gameById(id);
    return game?.system == 'pico8' ? game : null;
  }

  Future<String> _local({required bool favouritesOnly}) async {
    final carts = await db
        .watchGames(system: 'pico8', sort: LibrarySort.title)
        .first;
    final bySha1 = await credits.load();
    return [
      for (final g
          in carts
              .where((g) => !favouritesOnly || g.favorite)
              .take(maxLocalCarts))
        _record([
          '${g.id}',
          g.title,
          bySha1[g.sha1]?.author ?? '',
          g.favorite ? '1' : '0',
        ]),
    ].join();
  }

  Future<(String, bool)> _bbsList(String arg) async {
    final parts = arg.split(' ');
    final page = parts.length > 1 ? int.tryParse(parts[1]) : null;
    final BbsQuery? query = switch (parts[0]) {
      'f' => const FeaturedCarts(),
      'n' => const NewCarts(),
      's' when parts.length > 2 => SearchCarts(parts.sublist(2).join(' ')),
      _ => null,
    };
    if (query == null || page == null || page < 1) {
      return ('bad request', true);
    }
    final result = await client!.list(query, page: page);
    if (page == 1) _bbs.clear();
    final first = _bbs.length;
    _bbs.addAll(result.carts);
    final lines = StringBuffer(_record(['more', result.hasMore ? '1' : '0']));
    for (var i = first; i < _bbs.length; i++) {
      final c = _bbs[i];
      final id = await _libraryId(c);
      lines.write(_record(['$i', c.title, c.author, id?.toString() ?? '-']));
    }
    return (lines.toString(), false);
  }

  Future<(String, bool)> _get(String arg) async {
    final i = int.tryParse(arg.trim());
    if (i == null || i < 0 || i >= _bbs.length) return ('bad request', true);
    final cart = _bbs[i];
    final result = await downloadCart(
      client: client!,
      cart: cart,
      importer: importer,
      credits: credits,
    );
    final id = await _libraryId(cart);
    if (id == null) return ('that cart could not be added', true);
    return ('${result == DownloadResult.added ? 'ok' : 'dup'} $id', false);
  }

  /// The library id of the cart downloaded from [cart]'s post, if any.
  Future<int?> _libraryId(BbsCart cart) async {
    final sha1 = await credits.sha1ForPost(cart.postId);
    if (sha1 == null) return null;
    return (await db.gameBySha1(sha1))?.id;
  }
}

/// What the cart shows when a BBS request finds no network: one PICO-8
/// status line (32 characters).
const noNetworkMessage = 'no internet: connect to wi-fi';

/// Whether any network interface besides loopback has an address (Wi-Fi
/// joined, or mobile data on a phone). Errors count as connected, so the
/// BBS request still runs and reports its own failure.
Future<bool> deviceHasNetwork() async {
  try {
    final interfaces = await NetworkInterface.list();
    return interfaces.any((i) => i.addresses.isNotEmpty);
  } on Object {
    return true;
  }
}

/// One tab-separated record; fields lose their own tabs and newlines.
String _record(List<String> fields) =>
    '${fields.map((f) => f.replaceAll(RegExp(r'[\t\r\n]'), ' ')).join('\t')}\n';

/// Text the cart can print: lowercase (PICO-8 draws it as its normal
/// letters), tab and newline kept, anything else outside 32–126 as `?`.
String cartText(String text) => String.fromCharCodes(
  text.toLowerCase().runes.map(
    (c) => c == 9 || c == 10 || (c >= 32 && c <= 126) ? c : 0x3f,
  ),
);
