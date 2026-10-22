// SPDX-License-Identifier: GPL-3.0-or-later
// Settings > Files > USB storage on the single-card handheld system: asks
// dena-session for USB storage mode and closes the launcher.
// Spec: docs/specs/handheld-ui.md (USB storage), single-card.md
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'handheld.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// The launcher's side of USB storage mode: leave the request file and exit;
/// dena-session serves the games partition and starts the launcher again.
class UsbStorage {
  UsbStorage({
    required this.requestFile,
    this.beforeExit,
    void Function(int code)? exitApp,
  }) : _exit = exitApp ?? exit;

  /// `/run/dena/usb-storage`, which dena-session looks for after the launcher.
  final File requestFile;

  /// Closes what must be flushed before the process ends (the library db).
  final Future<void> Function()? beforeExit;

  final void Function(int code) _exit;

  /// The helper dena-session runs; only the single-card system has it. The
  /// stock-firmware boot hook has no session loop to come back to.
  static const helper = '/usr/lib/dena/system/dena-usb-storage';

  /// Where the kernel lists USB device controllers; none means the port
  /// can't act as a drive.
  static const udcs = '/sys/class/udc';

  /// Null unless the app is the launcher of the single-card system on a
  /// handheld whose USB port can act as a drive.
  static UsbStorage? detect({
    required bool handheld,
    Future<void> Function()? beforeExit,
    String helperPath = helper,
    String runDir = '/run/dena',
    String udcDir = udcs,
  }) {
    if (!handheld || !File(helperPath).existsSync()) return null;
    final udc = Directory(udcDir);
    try {
      if (!udc.existsSync() || udc.listSync().isEmpty) return null;
    } on FileSystemException {
      return null;
    }
    return UsbStorage(
      requestFile: File('$runDir/usb-storage'),
      beforeExit: beforeExit,
    );
  }

  /// Writes the request and exits; throws if the request can't be written
  /// (the launcher then stays up).
  Future<void> enter() async {
    await requestFile.parent.create(recursive: true);
    await requestFile.writeAsString('', flush: true);
    try {
      await beforeExit?.call();
    } on Object catch (e) {
      debugPrint('USB storage: closing before exit failed: $e');
    }
    _exit(0);
  }
}

/// The Settings tile that opens [UsbStoragePage].
class UsbStorageTile extends StatelessWidget {
  const UsbStorageTile({super.key, required this.usb});

  final UsbStorage usb;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(DenaIcons.usb),
    title: const Text('USB storage'),
    subtitle: const Text('Copy games from a computer over USB-C'),
    trailing: const Icon(DenaIcons.chevronRight),
    onTap: () => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => UsbStoragePage(usb: usb))),
  );
}

/// Confirms USB storage mode: what happens and how to come back.
class UsbStoragePage extends StatefulWidget {
  const UsbStoragePage({super.key, required this.usb});

  final UsbStorage usb;

  @override
  State<UsbStoragePage> createState() => _UsbStoragePageState();
}

class _UsbStoragePageState extends State<UsbStoragePage> {
  bool starting = false;
  String? error;

  Future<void> _start() async {
    setState(() {
      starting = true;
      error = null;
    });
    try {
      await widget.usb.enter();
    } on Object catch (e) {
      debugPrint('USB storage: $e');
      if (mounted) {
        setState(() {
          starting = false;
          error = 'Could not start USB storage. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    Widget step(String n, String line) => Padding(
      padding: const EdgeInsets.only(bottom: BrutalTokens.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$n ', style: t.label.copyWith(color: t.mutedText)),
          Expanded(child: Text(line, style: t.body)),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('USB STORAGE')),
      body: BrutalGridPaper(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(BrutalTokens.s3),
            children: [
              BrutalPanel(
                header: 'USB.MODE',
                padding: const EdgeInsets.all(BrutalTokens.s3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        BrutalTokens.s1,
                        BrutalTokens.s2,
                        0,
                        BrutalTokens.s3,
                      ),
                      child: Sticker(starting ? 'Mounting' : 'Ejected'),
                    ),
                    step(
                      '01',
                      'Connect the handheld to a computer with a USB-C cable.',
                    ),
                    step(
                      '02',
                      'Dena.emu closes and the games card shows up on the '
                          'computer as a drive. Copy games into Roms.',
                    ),
                    step(
                      '03',
                      'To come back, eject the drive on the computer, unplug '
                          'the cable or press the power key. With no computer, '
                          'Dena.emu returns after 2 minutes.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: BrutalTokens.s2),
              if (error case final e?)
                LogLine(e, status: LogStatus.err)
              else
                LogLine(
                  starting ? 'usb storage on' : 'usb storage off',
                  status: starting ? LogStatus.ok : LogStatus.none,
                ),
              const SizedBox(height: BrutalTokens.s3),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: BrutalTokens.s2,
                runSpacing: BrutalTokens.s2,
                children: [
                  BrutalButton(
                    label: 'Cancel',
                    onPressed: starting
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                  BrutalButton(
                    label: starting ? 'Starting…' : 'Start USB storage',
                    icon: DenaIcons.usb,
                    variant: BrutalButtonVariant.primary,
                    autofocus: true,
                    onPressed: starting ? null : _start,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Handheld.of(context)
          ? const BrutalHintBar(
              hints: [
                ([HintButton.a], 'Select'),
                ([HintButton.b], 'Back'),
              ],
            )
          : null,
    );
  }
}
