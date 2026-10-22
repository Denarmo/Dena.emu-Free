// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Wi-Fi on the handheld: wpa_supplicant's networks through
// wpa_cli. Spec: docs/specs/handheld-ui.md (Wi-Fi), single-card.md (Wi-Fi)
import 'dart:convert';
import 'dart:io';

/// Runs `wpa_cli` with [args] and returns its output, or throws.
typedef WpaRunner = Future<String> Function(List<String> args);

/// A network seen in the last scan; the strongest access point per name.
class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.secured,
  });

  final String ssid;

  /// dBm, e.g. -55 (higher is stronger).
  final int signal;

  /// Needs a password (WPA/WPA2/WPA3 personal).
  final bool secured;

  /// 0 to 4 bars.
  int get bars => switch (signal) {
    >= -55 => 4,
    >= -65 => 3,
    >= -75 => 2,
    >= -85 => 1,
    _ => 0,
  };
}

/// A network saved in `Dena/user/wpa_supplicant.conf`.
class SavedNetwork {
  const SavedNetwork({
    required this.id,
    required this.ssid,
    required this.current,
  });

  final String id;
  final String ssid;

  /// The one wpa_supplicant uses right now.
  final bool current;
}

/// What wpa_supplicant is doing.
class WifiStatus {
  const WifiStatus({required this.state, this.ssid, this.ip});

  /// `wpa_state`: COMPLETED, SCANNING, ASSOCIATING, DISCONNECTED, ...
  final String state;
  final String? ssid;
  final String? ip;

  bool get connected => state == 'COMPLETED';

  String get summary => switch (state) {
    'COMPLETED' when ip != null => 'Connected to $ssid',
    'COMPLETED' => 'Connected to $ssid, getting an address…',
    'ASSOCIATING' ||
    'ASSOCIATED' ||
    '4WAY_HANDSHAKE' ||
    'GROUP_HANDSHAKE' => 'Connecting${ssid == null ? '' : ' to $ssid'}…',
    'SCANNING' => 'Looking for networks…',
    'INTERFACE_DISABLED' => 'Wi-Fi is off',
    _ => 'Not connected',
  };
}

/// wpa_supplicant on `wlan0` (started by dena-net), through `wpa_cli`. Every
/// change is saved back to the card with `save_config`.
class WifiControl {
  WifiControl({WpaRunner? run}) : _run = run ?? _wpaCli;

  final WpaRunner _run;

  static const interface = 'wlan0';
  static const ctrlDir = '/run/wpa_supplicant';

  static Future<String> _wpaCli(List<String> args) async {
    final exe = [
      '/usr/sbin/wpa_cli',
      '/sbin/wpa_cli',
      '/usr/bin/wpa_cli',
    ].firstWhere((p) => File(p).existsSync(), orElse: () => 'wpa_cli');
    final r = await Process.run(exe, [
      '-p',
      ctrlDir,
      '-i',
      interface,
      ...args,
    ], stdoutEncoding: utf8);
    final out = r.stdout as String;
    if (r.exitCode != 0 || out.startsWith('Failed to connect')) {
      throw WifiException('wpa_cli ${args.first}: ${out.trim()} ${r.stderr}');
    }
    return out;
  }

  /// Runs a command that answers OK.
  Future<void> _ok(List<String> args) async {
    final out = (await _run(args)).trim();
    if (out != 'OK') throw WifiException('wpa_cli ${args.first}: $out');
  }

  Future<WifiStatus> status() async {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(await _run(['status']))) {
      final i = line.indexOf('=');
      if (i > 0) values[line.substring(0, i)] = line.substring(i + 1);
    }
    return WifiStatus(
      state: values['wpa_state'] ?? 'UNKNOWN',
      ssid: values['ssid'] == null ? null : decodeSsid(values['ssid']!),
      ip: values['ip_address'],
    );
  }

  /// Starts a scan; results arrive a few seconds later ([networks]).
  /// A scan already running answers FAIL-BUSY, which is fine.
  Future<void> scan() async {
    final out = (await _run(['scan'])).trim();
    if (out != 'OK' && out != 'FAIL-BUSY') {
      throw WifiException('wpa_cli scan: $out');
    }
  }

  /// The last scan, strongest first; hidden networks are left out.
  Future<List<WifiNetwork>> networks() async =>
      parseScanResults(await _run(['scan_results']));

  Future<List<SavedNetwork>> saved() async =>
      parseNetworkList(await _run(['list_networks']));

  /// Joins [ssid]: a saved network is selected again (with a new [password]
  /// when one is given), anything else is added. Saved to the card.
  Future<void> connect(String ssid, {String? password}) async {
    final known = (await saved()).where((n) => n.ssid == ssid);
    final String id;
    if (known.isNotEmpty) {
      id = known.first.id;
    } else {
      id = (await _run(['add_network'])).trim();
      if (int.tryParse(id) == null) {
        throw WifiException('wpa_cli add_network: $id');
      }
      // Hex: any name, also quotes and non-ASCII, gets through as is.
      await _ok(['set_network', id, 'ssid', hexSsid(ssid)]);
    }
    if (password != null) {
      await _ok(['set_network', id, 'psk', quotePsk(password)]);
    } else if (known.isEmpty) {
      await _ok(['set_network', id, 'key_mgmt', 'NONE']);
    }
    await _ok(['select_network', id]);
    // select_network disables the others; saved networks should all stay
    // usable when this one is out of range.
    for (final other in await saved()) {
      if (other.id != id) await _ok(['enable_network', other.id]);
    }
    await _ok(['save_config']);
  }

  /// Removes a saved network from the card.
  Future<void> forget(SavedNetwork network) async {
    await _ok(['remove_network', network.id]);
    await _ok(['save_config']);
  }
}

class WifiException implements Exception {
  const WifiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A WPA passphrase is 8 to 63 printable ASCII characters.
bool validPassword(String password) =>
    password.length >= 8 &&
    password.length <= 63 &&
    password.codeUnits.every((c) => c >= 0x20 && c <= 0x7e);

/// [ssid] as wpa_supplicant's unquoted hex form.
String hexSsid(String ssid) =>
    [for (final b in utf8.encode(ssid)) b.toRadixString(16).padLeft(2, '0')]
        .join();

/// [password] in quotes, as wpa_supplicant wants a passphrase.
String quotePsk(String password) => '"$password"';

/// Undoes wpa_supplicant's escaping of names in its output (`\xNN`, `\\`,
/// `\"`), then reads the bytes as UTF-8.
String decodeSsid(String s) {
  if (!s.contains(r'\')) return s;
  final bytes = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (n == 'x' && i + 3 < s.length) {
        final v = int.tryParse(s.substring(i + 2, i + 4), radix: 16);
        if (v != null) {
          bytes.add(v);
          i += 3;
          continue;
        }
      }
      final simple = switch (n) {
        r'\' => 0x5c,
        '"' => 0x22,
        'n' => 0x0a,
        'r' => 0x0d,
        't' => 0x09,
        'e' => 0x1b,
        _ => null,
      };
      if (simple != null) {
        bytes.add(simple);
        i += 1;
        continue;
      }
    }
    bytes.addAll(utf8.encode(c));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

final _bssid = RegExp(r'^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$');

/// `scan_results`: `bssid \t frequency \t signal \t flags \t ssid` rows after
/// a header. One entry per name, the strongest; strongest first.
List<WifiNetwork> parseScanResults(String out) {
  final best = <String, WifiNetwork>{};
  for (final line in const LineSplitter().convert(out)) {
    final f = line.split('\t');
    if (f.length < 5 || !_bssid.hasMatch(f[0])) continue;
    final ssid = decodeSsid(f.sublist(4).join('\t'));
    if (ssid.isEmpty || ssid.codeUnits.every((c) => c == 0)) continue;
    final flags = f[3];
    final n = WifiNetwork(
      ssid: ssid,
      signal: int.tryParse(f[2]) ?? -100,
      secured: flags.contains('WPA') || flags.contains('RSN'),
    );
    final old = best[ssid];
    if (old == null || n.signal > old.signal) best[ssid] = n;
  }
  return best.values.toList()..sort((a, b) => b.signal.compareTo(a.signal));
}

/// `list_networks`: `id \t ssid \t bssid \t flags` rows after a header.
List<SavedNetwork> parseNetworkList(String out) => [
  for (final line in const LineSplitter().convert(out))
    if (line.split('\t') case final f
        when f.length >= 2 && int.tryParse(f[0]) != null)
      SavedNetwork(
        id: f[0],
        ssid: decodeSsid(f[1]),
        current: f.length > 3 && f[3].contains('[CURRENT]'),
      ),
];
