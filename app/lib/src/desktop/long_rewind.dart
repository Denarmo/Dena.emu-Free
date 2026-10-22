// SPDX-License-Identifier: GPL-3.0-or-later
// Long rewind on Windows and SteamOS: the buffer setting, the host calls and
// the pause menu's scrub sheet. Spec: docs/specs/rewind.md (Long rewind)
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/handheld.dart' show arrowsMoveFocus;
import '../shell/host_library.dart';
import '../shell/platform_features.dart';
import '../ui/brutal/brutal.dart';

/// How much memory the rewind buffer may use. The buffer only grows as the
/// game plays, so a big choice costs nothing until minutes have passed.
enum RewindBuffer {
  short(32, 'Short'), // the phones' buffer: seconds
  mb256(256, '256 MB'),
  gb1(1024, '1 GB'),
  gb2(2048, '2 GB');

  const RewindBuffer(this.megabytes, this.label);

  final int megabytes;
  final String label;

  int get bytes => megabytes << 20;
}

/// The desktop's rewind choice, kept in `desktop_rewind.json` in the data
/// folder.
class DesktopRewindSettings extends ChangeNotifier {
  DesktopRewindSettings({this.file, this._buffer = RewindBuffer.gb1});

  /// Reads [file]; a missing or damaged file gives the default (1 GB).
  factory DesktopRewindSettings.load(File file) {
    var buffer = RewindBuffer.gb1;
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map) {
          buffer = RewindBuffer.values.firstWhere(
            (b) => b.name == j['buffer'],
            orElse: () => RewindBuffer.gb1,
          );
        }
      }
    } on Object {
      // Default; the next change rewrites the file.
    }
    return DesktopRewindSettings(file: file, buffer: buffer);
  }

  final File? file;
  RewindBuffer _buffer;

  RewindBuffer get buffer => _buffer;

  set buffer(RewindBuffer value) {
    if (value == _buffer) return;
    _buffer = value;
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'buffer': value.name}));
    } on Object catch (e) {
      debugPrint('Rewind settings not saved: $e');
    }
  }
}

/// Gives Settings and the game session the rewind choice; absent off the
/// desktop.
class DesktopRewindScope extends InheritedNotifier<DesktopRewindSettings> {
  const DesktopRewindScope({
    super.key,
    required DesktopRewindSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static DesktopRewindSettings? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DesktopRewindScope>()
      ?.notifier;
}

/// The `REWIND BUFFER  SHORT 256 MB [1 GB] 2 GB` row of Settings > INPUT.CFG.
class RewindBufferTile extends StatelessWidget {
  const RewindBufferTile({super.key, required this.settings});

  final DesktopRewindSettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => CfgRow(
      label: 'Rewind buffer',
      control: CfgSegment<RewindBuffer>(
        values: RewindBuffer.values,
        selected: settings.buffer,
        labelOf: (b) => b.label,
        onChanged: (b) => settings.buffer = b,
      ),
    ),
  );
}

/// What the rewind buffer holds right now (dena_rewind_info).
@immutable
class RewindInfo {
  const RewindInfo({
    required this.count,
    required this.position,
    this.bytes = 0,
    this.budget = 0,
    this.fps = 60,
  });

  /// Captures behind the newest state.
  final int count;

  /// Where the scrub is: 0 the oldest capture, [count] the newest.
  final int position;
  final int bytes, budget;
  final double fps;

  /// A capture every 2 frames (Runner::kRewindInterval).
  static const framesPerCapture = 2;

  double get capturesPerSecond => fps / framesPerCapture;

  /// How far back [position] is from the newest capture.
  Duration behind(int position) => Duration(
    milliseconds:
        ((count - position.clamp(0, count)) * 1000 / capturesPerSecond).round(),
  );

  /// All the buffer holds.
  Duration get length => behind(0);

  /// [position] moved by [seconds] (negative = back), within the buffer.
  int step(int position, double seconds) =>
      (position + (seconds * capturesPerSecond).round()).clamp(0, count);

  static RewindInfo? fromList(List<int> v, {required int position}) =>
      v.length < 5
      ? null
      : RewindInfo(
          count: v[0],
          position: position,
          bytes: v[2],
          budget: v[3],
          fps: v[4] / 1000,
        );
}

/// `-01:23`, `00:00`; hours as `1:02:03`.
String formatRewindTime(Duration d, {bool minus = true}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final s = d.inSeconds;
  final body = s >= 3600
      ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}'
      : '${two(s ~/ 60)}:${two(s % 60)}';
  return minus && s > 0 ? '-$body' : body;
}

/// `412 MB`, `1.0 GB`.
String formatRewindBytes(int bytes) {
  final mb = bytes / (1 << 20);
  return mb >= 1024
      ? '${(mb / 1024).toStringAsFixed(1)} GB'
      : '${mb.round()} MB';
}

/// The host side of long rewind; null where the shell has no long rewind.
abstract class LongRewindHost {
  /// The buffer's budget for this game (a change empties the buffer).
  void setBudget(int bytes);

  /// Starts scrubbing the paused game; null when this game has no rewind.
  RewindInfo? begin();

  /// Shows capture [position] (0 oldest .. count newest); returns at once.
  void scrub(int position);

  /// Keeps the shown point (the game resumes from there) or goes back to
  /// where the game paused.
  void end({required bool keep});
}

/// [LongRewindHost] over dena_rewind_* in the desktop host library.
class FfiLongRewindHost implements LongRewindHost {
  FfiLongRewindHost._(DynamicLibrary lib)
    : _budget = lib.lookupFunction<Void Function(Int64), void Function(int)>(
        'dena_rewind_budget',
      ),
      _begin = lib
          .lookupFunction<
            Int32 Function(Pointer<Int64>),
            int Function(Pointer<Int64>)
          >('dena_rewind_scrub_begin'),
      _scrub = lib.lookupFunction<Void Function(Int64), void Function(int)>(
        'dena_rewind_scrub',
      ),
      _end = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'dena_rewind_scrub_end',
      );

  /// Only on Windows and SteamOS with a host library that has long rewind.
  static FfiLongRewindHost? open() {
    if (shellProfile != ShellProfile.desktop) return null;
    final lib = openHostLibrary();
    if (lib == null) return null;
    try {
      return FfiLongRewindHost._(lib);
    } on ArgumentError {
      return null; // an older library
    }
  }

  final void Function(int) _budget;
  final int Function(Pointer<Int64>) _begin;
  final void Function(int) _scrub;
  final void Function(int) _end;

  @override
  void setBudget(int bytes) => _budget(bytes);

  @override
  RewindInfo? begin() => using((arena) {
    final info = arena<Int64>(5);
    if (_begin(info) != 0) return null;
    final v = info.asTypedList(5).toList();
    return RewindInfo.fromList(v, position: v[1]);
  });

  @override
  void scrub(int position) => _scrub(position);

  @override
  void end({required bool keep}) => _end(keep ? 1 : 0);
}

/// The pause menu's REWIND sheet: a scrub bar over the buffer with the game
/// picture following it. Pops true for "resume from here".
class RewindScrubSheet extends StatefulWidget {
  const RewindScrubSheet({super.key, required this.info, required this.host});

  final RewindInfo info;
  final LongRewindHost host;

  /// Cells of the scrub bar.
  static const cells = 20;

  @override
  State<RewindScrubSheet> createState() => _RewindScrubSheetState();
}

class _ScrubIntent extends Intent {
  const _ScrubIntent(this.seconds);
  final double seconds;
}

class _RewindScrubSheetState extends State<RewindScrubSheet> {
  late int position = widget.info.position;

  RewindInfo get info => widget.info;

  void _moveTo(int p) {
    final next = p.clamp(0, info.count);
    if (next == position) return;
    setState(() => position = next);
    widget.host.scrub(next);
  }

  void _by(double seconds) => _moveTo(info.step(position, seconds));

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final empty = info.count == 0;
    final value = empty ? 1.0 : position / info.count;
    return Shortcuts(
      shortcuts: {
        ...arrowsMoveFocus,
        // Page keys and the shoulder buttons' keys jump 10 s anywhere.
        const SingleActivator(LogicalKeyboardKey.pageUp): const _ScrubIntent(
          -10,
        ),
        const SingleActivator(LogicalKeyboardKey.pageDown): const _ScrubIntent(
          10,
        ),
        const SingleActivator(LogicalKeyboardKey.gameButtonLeft1):
            const _ScrubIntent(-10),
        const SingleActivator(LogicalKeyboardKey.gameButtonRight1):
            const _ScrubIntent(10),
      },
      child: Actions(
        actions: {
          _ScrubIntent: CallbackAction<_ScrubIntent>(
            onInvoke: (i) => _by(i.seconds),
          ),
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(BrutalTokens.s2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                formatRewindTime(info.behind(position)),
                key: const ValueKey('rewind-time'),
                style: t.displaySmall.copyWith(color: t.ink),
              ),
              const SizedBox(height: BrutalTokens.s1),
              BracketSlider(
                value: value,
                steps: RewindScrubSheet.cells,
                showPercent: false,
                autofocus: true,
                semanticLabel: 'Rewind position',
                onChanged: empty
                    ? null
                    : (v) => _moveTo((v * info.count).round()),
              ),
              DefaultTextStyle(
                style: t.small.copyWith(color: t.mutedText),
                child: Row(
                  children: [
                    Text(formatRewindTime(info.length)),
                    const Spacer(),
                    const Text('NOW'),
                  ],
                ),
              ),
              const SizedBox(height: BrutalTokens.s2),
              Wrap(
                spacing: BrutalTokens.s1,
                runSpacing: BrutalTokens.s1,
                children: [
                  for (final s in const [-10.0, -1.0, 1.0, 10.0])
                    BrutalButton(
                      label: s < 0 ? '${s.round()}S' : '+${s.round()}S',
                      onPressed: empty ? null : () => _by(s),
                    ),
                ],
              ),
              const SizedBox(height: BrutalTokens.s2),
              BrutalButton(
                label: 'Resume here',
                variant: BrutalButtonVariant.primary,
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: BrutalTokens.s1),
              BrutalButton(
                label: 'Back to now',
                expand: true,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: BrutalTokens.s2),
              LogLine(
                empty
                    ? 'rewind: nothing captured yet'
                    : 'rewind: ${formatRewindTime(info.length, minus: false)} '
                          'in ${formatRewindBytes(info.bytes)} of '
                          '${formatRewindBytes(info.budget)}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
