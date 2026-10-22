// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/web-file-manager.md
import 'package:material_ui/material_ui.dart';

import '../library/library_scope.dart';
import '../shell/app_dirs.dart';
import '../ui/brutal/brutal.dart';
import 'qr_code.dart';
import 'web_file_server.dart';

/// Settings › Web file manager. The server runs only while this page is
/// open, so the phone never serves files the user forgot about.
class WebFilesPage extends StatefulWidget {
  const WebFilesPage({super.key, this.dataDir});

  /// Overrides the app-support folder (tests).
  final String? dataDir;

  @override
  State<WebFilesPage> createState() => _WebFilesPageState();
}

class _WebFilesPageState extends State<WebFilesPage> {
  WebFileServer? _server;
  List<String> _addresses = const [];
  String? _error;
  bool _busy = false;

  bool get _on => _server?.running ?? false;

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) {
        final scope = LibraryScope.of(context);
        final dir = widget.dataDir ?? (await appDataDir()).path;
        final server = WebFileServer(
          dataDir: dir,
          db: scope.db,
          importer: scope.importer,
        );
        await server.start();
        _server = server;
        _addresses = await server.addresses();
        _error = null;
      } else {
        await _server?.stop();
        _server = null;
        _addresses = const [];
      }
    } on Object catch (e) {
      _error = 'Could not start the server: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _server?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final handheld = t.density == BrutalDensity.handheld;
    final server = _server;
    return Scaffold(
      appBar: AppBar(title: const Text('WEB FILE MANAGER')),
      body: BrutalGridPaper(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.all(
              handheld ? BrutalTokens.s2 : BrutalTokens.s4,
            ),
            children: [
              CfgTable(
                header: 'SHARE.CFG',
                rows: [
                  CfgRow(
                    label: 'Share files over Wi-Fi',
                    control: CfgToggle(
                      value: _on,
                      autofocus: true,
                      semanticLabel: 'Share files over Wi-Fi',
                      onChanged: _busy ? null : _toggle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: BrutalTokens.s2),
              if (_error case final e?)
                LogLine(e, status: LogStatus.err)
              else
                LogLine(
                  _busy
                      ? (_on ? 'stop server' : 'start server')
                      : _on
                      ? 'server running; stops when you leave this page'
                      : 'manage games, saves, states, skins and carts from a browser',
                  status: _on && !_busy ? LogStatus.ok : LogStatus.none,
                ),
              if (_on && server != null) ...[
                SizedBox(height: handheld ? BrutalTokens.s2 : BrutalTokens.s4),
                WebFilesAddress(addresses: _addresses, code: server.code),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Where to point a browser: the address in a big read-only command box, a
/// QR code of it in a bordered panel and the access code
/// (brutalist-ui.md 4.9).
class WebFilesAddress extends StatelessWidget {
  const WebFilesAddress({
    super.key,
    required this.addresses,
    required this.code,
  });

  final List<String> addresses;
  final String code;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final handheld = t.density == BrutalDensity.handheld;
    final address = BrutalPanel(
      header: 'OPEN.IN.BROWSER',
      padding: const EdgeInsets.all(BrutalTokens.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (addresses.isEmpty)
            Text('Connect to Wi-Fi to see the address', style: t.body)
          else
            for (final a in addresses)
              Padding(
                padding: const EdgeInsets.only(bottom: BrutalTokens.s2),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: BrutalTokens.s3,
                    vertical: BrutalTokens.s2,
                  ),
                  decoration: t.panelDecoration(shadowed: false),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '> ',
                          style: TextStyle(color: t.mutedText),
                        ),
                        TextSpan(text: a),
                      ],
                    ),
                    style: t.title,
                  ),
                ),
              ),
          const SizedBox(height: BrutalTokens.s2),
          Text('ACCESS CODE', style: t.label.copyWith(color: t.mutedText)),
          Text(
            code,
            style: (handheld ? t.displaySmall : t.display).copyWith(
              letterSpacing: 8,
            ),
          ),
          const SizedBox(height: BrutalTokens.s2),
          Text(
            'Use a computer on the same network. Dropped game files are '
            'added to your library.',
            style: t.small.copyWith(color: t.mutedText),
          ),
        ],
      ),
    );
    if (addresses.isEmpty) return address;
    final QrCode qr;
    try {
      qr = QrCode.encode(addresses.first);
    } on ArgumentError {
      return address;
    }
    final qrPanel = BrutalPanel(
      header: 'SCAN.QR',
      padding: const EdgeInsets.all(BrutalTokens.s2),
      // Always dark on white, whatever the theme, so every camera reads it.
      child: QrCodeView(
        code: qr,
        dark: const Color(0xFF000000),
        light: const Color(0xFFFFFFFF),
        size: handheld ? 150 : 180,
        semanticLabel: 'QR code of ${addresses.first}',
      ),
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 520
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: address),
                const SizedBox(width: BrutalTokens.s3),
                IntrinsicWidth(child: qrPanel),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                address,
                const SizedBox(height: BrutalTokens.s3),
                IntrinsicWidth(child: qrPanel),
              ],
            ),
    );
  }
}
