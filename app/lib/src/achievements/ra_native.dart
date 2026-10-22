// SPDX-License-Identifier: GPL-3.0-or-later
// dart:ffi bindings to the host's RetroAchievements client
// (host/achievements/achievements.h). Spec: docs/specs/achievements.md
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../shell/host_library.dart';

/// The native client. The app implementation is [FfiRaNative]; tests use a
/// fake. Strings in and out are UTF-8; JSON values are decoded maps.
abstract interface class RaNative {
  String userAgentClause();
  void login(String user, String secret, {required bool token});
  void logout();
  void setHardcore(bool on);

  /// The next HTTP request to send, or null.
  Map<String, Object?>? takeRequest();
  void respond(int id, int status, List<int> body);

  /// The next event, or null.
  Map<String, Object?>? takeEvent();
  void pump();

  void sessionBegin(String path, int consoleId);
  void sessionEnd();

  /// The running game's achievements, or null when none is loaded.
  List<Object?>? sessionList();
  void fetchGame(String path, int consoleId, int seq);
}

class FfiRaNative implements RaNative {
  FfiRaNative._(DynamicLibrary lib)
    : _buffer = lib
          .lookupFunction<
            Pointer<Uint8> Function(Int32),
            Pointer<Uint8> Function(int)
          >('dena_ra_buffer'),
      _ua = lib
          .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
            'dena_ra_user_agent_clause',
          ),
      _login = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'dena_ra_login',
      ),
      _logout = lib.lookupFunction<Void Function(), void Function()>(
        'dena_ra_logout',
      ),
      _hardcore = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'dena_ra_set_hardcore',
      ),
      _takeRequest = lib
          .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
            'dena_ra_take_request',
          ),
      _respond = lib
          .lookupFunction<
            Void Function(Int32, Int32, Int32),
            void Function(int, int, int)
          >('dena_ra_respond'),
      _takeEvent = lib
          .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
            'dena_ra_take_event',
          ),
      _pump = lib.lookupFunction<Void Function(), void Function()>(
        'dena_ra_pump',
      ),
      _begin = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'dena_ra_session_begin',
      ),
      _end = lib.lookupFunction<Void Function(), void Function()>(
        'dena_ra_session_end',
      ),
      _list = lib
          .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
            'dena_ra_session_list',
          ),
      _fetch = lib
          .lookupFunction<Void Function(Int32, Int32), void Function(int, int)>(
            'dena_ra_fetch_game',
          );

  /// The shell's client, or null where it has none (desktop, tests, a shell
  /// built without achievements).
  static FfiRaNative? open() {
    try {
      final lib = openHostLibrary();
      return lib == null ? null : FfiRaNative._(lib);
    } on ArgumentError {
      return null;
    }
  }

  final Pointer<Uint8> Function(int) _buffer;
  final Pointer<Uint8> Function() _ua;
  final void Function(int) _login;
  final void Function() _logout;
  final void Function(int) _hardcore;
  final Pointer<Uint8> Function() _takeRequest;
  final void Function(int, int, int) _respond;
  final Pointer<Uint8> Function() _takeEvent;
  final void Function() _pump;
  final void Function(int) _begin;
  final void Function() _end;
  final Pointer<Uint8> Function() _list;
  final void Function(int, int) _fetch;

  /// Copies NUL-separated [fields] into the input buffer.
  void _put(List<String> fields) {
    final bytes = BytesBuilder();
    for (final f in fields) {
      bytes
        ..add(utf8.encode(f))
        ..addByte(0);
    }
    final data = bytes.takeBytes();
    _buffer(data.length).asTypedList(data.length).setAll(0, data);
  }

  static String? _string(Pointer<Uint8> p) {
    if (p == nullptr) return null;
    var n = 0;
    while (p[n] != 0) {
      n++;
    }
    return utf8.decode(p.asTypedList(n), allowMalformed: true);
  }

  static Map<String, Object?>? _map(Pointer<Uint8> p) {
    final s = _string(p);
    return s == null ? null : jsonDecode(s) as Map<String, Object?>;
  }

  @override
  String userAgentClause() => _string(_ua()) ?? '';

  @override
  void login(String user, String secret, {required bool token}) {
    _put([user, secret]);
    _login(token ? 1 : 0);
  }

  @override
  void logout() => _logout();

  @override
  void setHardcore(bool on) => _hardcore(on ? 1 : 0);

  @override
  Map<String, Object?>? takeRequest() => _map(_takeRequest());

  @override
  void respond(int id, int status, List<int> body) {
    _buffer(body.length).asTypedList(body.length).setAll(0, body);
    _respond(id, status, body.length);
  }

  @override
  Map<String, Object?>? takeEvent() => _map(_takeEvent());

  @override
  void pump() => _pump();

  @override
  void sessionBegin(String path, int consoleId) {
    _put([path]);
    _begin(consoleId);
  }

  @override
  void sessionEnd() => _end();

  @override
  List<Object?>? sessionList() {
    final s = _string(_list());
    return s == null ? null : jsonDecode(s) as List<Object?>;
  }

  @override
  void fetchGame(String path, int consoleId, int seq) {
    _put([path]);
    _fetch(consoleId, seq);
  }
}
