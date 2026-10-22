// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Wi-Fi on the handheld. Spec: docs/specs/handheld-ui.md (Wi-Fi)
import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';
import '../ui/onscreen_keyboard.dart';
import 'wifi.dart';

/// The Settings tile that opens [WifiPage].
class WifiTile extends StatelessWidget {
  const WifiTile({super.key, required this.wifi});

  final WifiControl wifi;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(DenaIcons.network),
    title: const Text('Wi-Fi'),
    subtitle: const Text('Join a network, saved networks'),
    onTap: () => Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => WifiPage(wifi: wifi))),
  );
}

/// The networks around, the saved ones and the connection, refreshed every
/// few seconds while open.
class WifiPage extends StatefulWidget {
  const WifiPage({
    super.key,
    required this.wifi,
    this.refreshEvery = const Duration(seconds: 3),
  });

  final WifiControl wifi;
  final Duration refreshEvery;

  @override
  State<WifiPage> createState() => _WifiPageState();
}

class _WifiPageState extends State<WifiPage> {
  WifiStatus? status;
  List<WifiNetwork> networks = const [];
  List<SavedNetwork> saved = const [];
  bool loaded = false;
  bool running = true;
  String? busy;
  Timer? _timer;

  /// The last action and how it went: `> connect home ... ok`.
  (String, LogStatus)? log;

  @override
  void initState() {
    super.initState();
    _scan();
    _timer = Timer.periodic(widget.refreshEvery, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    try {
      await widget.wifi.scan();
    } on Object catch (e) {
      debugPrint('Wi-Fi scan: $e');
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.wifi.status();
      final n = await widget.wifi.networks();
      final k = await widget.wifi.saved();
      if (!mounted) return;
      setState(() {
        status = s;
        networks = n;
        saved = k;
        loaded = true;
        running = true;
      });
    } on Object catch (e) {
      debugPrint('Wi-Fi: $e');
      if (mounted) {
        setState(() {
          loaded = true;
          running = false;
        });
      }
    }
  }

  void _say(String message, {String? entry, LogStatus? status}) {
    if (!mounted) return;
    if (entry != null) setState(() => log = (entry, status ?? LogStatus.none));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _join(String ssid, {String? password}) async {
    setState(() {
      busy = ssid;
      log = ('connect $ssid', LogStatus.none);
    });
    try {
      await widget.wifi.connect(ssid, password: password);
      _say(
        'Connecting to $ssid…',
        entry: 'connect $ssid',
        status: LogStatus.ok,
      );
    } on Object catch (e) {
      debugPrint('Wi-Fi connect: $e');
      _say(
        "Couldn't join $ssid",
        entry: 'connect $ssid',
        status: LogStatus.err,
      );
    }
    if (mounted) setState(() => busy = null);
    await _refresh();
  }

  Future<void> _tapNetwork(WifiNetwork n) async {
    if (status?.connected == true && status?.ssid == n.ssid) {
      return _say('Already connected to ${n.ssid}');
    }
    final known = saved.any((s) => s.ssid == n.ssid);
    if (known || !n.secured) return _join(n.ssid);
    final password = await _askPassword(n.ssid);
    if (password != null) await _join(n.ssid, password: password);
  }

  Future<String?> _askPassword(String ssid) => showOnScreenKeyboard(
    context,
    title: 'Password for $ssid',
    obscure: true,
    accept: validPassword,
    hint: '8 to 63 characters',
  );

  Future<void> _tapSaved(SavedNetwork n) async {
    final action = await showBrutalDialog<String>(
      context: context,
      builder: (context) => BrutalDialog(
        title: n.ssid,
        body: Text(n.current ? 'In use' : 'Saved network'),
        actions: [
          BrutalDialogAction(
            label: 'Forget',
            onPressed: () => Navigator.of(context).pop('forget'),
          ),
          BrutalDialogAction(
            label: 'New password',
            onPressed: () => Navigator.of(context).pop('password'),
          ),
          BrutalDialogAction(
            label: 'Connect',
            primary: true,
            autofocus: true,
            onPressed: () => Navigator.of(context).pop('connect'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'connect':
        await _join(n.ssid);
      case 'password':
        final password = await _askPassword(n.ssid);
        if (password != null) await _join(n.ssid, password: password);
      case 'forget':
        try {
          await widget.wifi.forget(n);
          _say(
            'Forgot ${n.ssid}',
            entry: 'forget ${n.ssid}',
            status: LogStatus.ok,
          );
        } on Object catch (e) {
          debugPrint('Wi-Fi forget: $e');
          _say(
            "Couldn't forget ${n.ssid}",
            entry: 'forget ${n.ssid}',
            status: LogStatus.err,
          );
        }
        await _refresh();
    }
  }

  /// `[####-]`: the signal as five cells.
  static String signalBars(int bars) {
    final n = bars.clamp(0, 4) + 1;
    return '[${'#' * n}${'-' * (5 - n)}]';
  }

  String _state(WifiNetwork n, String? current) => n.ssid == current
      ? 'Connected'
      : busy == n.ssid
      ? 'Connecting…'
      : saved.any((s) => s.ssid == n.ssid)
      ? 'Saved'
      : n.secured
      ? 'Password needed'
      : 'Open';

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final handheld = t.density == BrutalDensity.handheld;
    final current = status?.connected == true ? status?.ssid : null;
    final (logText, logStatus) =
        log ??
        (
          !loaded
              ? 'checking wi-fi'
              : running
              ? 'scan every ${widget.refreshEvery.inSeconds} s'
              : 'wpa_supplicant not answering',
          !loaded || running ? LogStatus.none : LogStatus.err,
        );
    final gap = SizedBox(height: handheld ? BrutalTokens.s2 : BrutalTokens.s4);
    return Scaffold(
      appBar: AppBar(title: const Text('WI-FI')),
      body: BrutalGridPaper(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.all(
              handheld ? BrutalTokens.s2 : BrutalTokens.s3,
            ),
            children: [
              BrutalPanel(
                header: 'WIFI.STATUS',
                child: KeyValueStrip(
                  entries: [
                    (
                      'Status',
                      !loaded
                          ? 'Checking…'
                          : running
                          ? status!.summary
                          : "Wi-Fi isn't running",
                    ),
                    if (!running && loaded)
                      ('Help', 'Restart the device to try again')
                    else if (status?.ip case final ip?)
                      ('IP', ip),
                  ],
                ),
              ),
              const SizedBox(height: BrutalTokens.s2),
              Wrap(
                spacing: BrutalTokens.s4,
                runSpacing: BrutalTokens.s2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  BrutalButton(
                    label: 'Look for networks',
                    icon: DenaIcons.refresh,
                    autofocus: true,
                    onPressed: _scan,
                  ),
                  LogLine(logText, status: logStatus),
                ],
              ),
              if (running && loaded) ...[
                gap,
                if (networks.isEmpty)
                  const BrutalPanel(
                    header: 'NETWORKS',
                    padding: EdgeInsets.all(BrutalTokens.s3),
                    child: Text('No networks found yet'),
                  )
                else
                  LayoutBuilder(
                    builder: (context, box) {
                      final wide = box.maxWidth >= 520;
                      return BrutalTable(
                        shrinkWrap: true,
                        columns: [
                          const BrutalColumn('SSID', flex: 3),
                          const BrutalColumn('Signal', width: 76),
                          if (wide) const BrutalColumn('Security', flex: 2),
                          const BrutalColumn('', width: 40),
                        ],
                        rowCount: networks.length,
                        onRowPressed: busy == null
                            ? (i) => _tapNetwork(networks[i])
                            : null,
                        cellBuilder: (context, i, c, lit) {
                          final n = networks[i];
                          final col = wide || c < 2 ? c : c + 1;
                          return switch (col) {
                            0 => Text(n.ssid),
                            1 => Text(signalBars(n.bars)),
                            2 => Text(
                              _state(n, current),
                              style: TextStyle(color: lit ? null : t.mutedText),
                            ),
                            _ => Text(n.ssid == current ? '[x]' : '[ ]'),
                          };
                        },
                      );
                    },
                  ),
                if (saved.isNotEmpty) ...[
                  gap,
                  BrutalTable(
                    shrinkWrap: true,
                    columns: const [
                      BrutalColumn('Saved', flex: 3),
                      BrutalColumn('State', flex: 2),
                    ],
                    rowCount: saved.length,
                    onRowPressed: busy == null
                        ? (i) => _tapSaved(saved[i])
                        : null,
                    cellBuilder: (context, i, c, lit) {
                      final n = saved[i];
                      return c == 0
                          ? Text(n.ssid)
                          : Text(
                              n.current ? '[IN USE]' : '[SAVED]',
                              style: TextStyle(color: lit ? null : t.mutedText),
                            );
                    },
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
