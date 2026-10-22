// SPDX-License-Identifier: GPL-3.0-or-later
// Disc conversion to CHD (chdman) and RVZ (DolphinTool), one job at a time.
// Spec: docs/specs/rom-manager.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/database.dart';

/// The container a disc image converts to.
enum ConvertFormat { chd, rvz }

/// Systems whose discs convert to RVZ (GameCube, Wii); none in the app yet.
const rvzSystems = <String>{'gamecube', 'wii'};

/// Systems whose `.iso` images convert with `chdman createdvd`.
const _dvdSystems = <String>{'psp', 'ps2'};

/// What converting one game does: the tool, its input, the files it replaces
/// and where the result goes.
class ConversionPlan {
  ConversionPlan({
    required this.format,
    required this.input,
    required this.originals,
    required this.output,
    required this.part,
    this.dvd = false,
  });

  final ConvertFormat format;

  /// Whether chdman makes a DVD CHD (`createdvd`) rather than a CD one.
  final bool dvd;

  /// The file given to the tool (`.cue`, `.gdi`, `.toc`, `.iso`, ...).
  final File input;

  /// [input] plus every track its sheet lists, deduplicated: deleted after a
  /// successful conversion unless KEEP ORIGINALS is on.
  final List<File> originals;

  /// `<folder>/<input base name>.chd` or `.rvz`.
  final File output;

  /// `<folder>/.<input base name>.<chd|rvz>.part`, hidden so the folder
  /// scanner ignores it.
  final File part;

  /// `chdman` or `dolphintool` (the name [ToolLocator.find] takes).
  String get tool => format == ConvertFormat.chd ? 'chdman' : 'dolphintool';

  /// Arguments that write [part] from [input].
  List<String> get convertArgs => switch (format) {
    ConvertFormat.chd => [
      dvd ? 'createdvd' : 'createcd',
      '-i',
      input.path,
      '-o',
      part.path,
      '-f',
    ],
    ConvertFormat.rvz => [
      'convert',
      '-f',
      'rvz',
      '-b',
      '131072',
      '-c',
      'zstd',
      '-l',
      '5',
      '-i',
      input.path,
      '-o',
      part.path,
    ],
  };

  /// Arguments that check [part] (the same for both tools).
  List<String> get verifyArgs => ['verify', '-i', part.path];
}

/// The plan for [game], or null when its file doesn't convert (already
/// compressed, a cartridge, or a system with no target format).
ConversionPlan? planFor(Game game) {
  final input = File(game.path);
  final ext = p.extension(game.path).toLowerCase();
  final ConvertFormat format;
  var dvd = false;
  var tracks = const <String>[];
  switch (ext) {
    case '.cue' || '.gdi' || '.toc':
      format = ConvertFormat.chd;
      tracks = _readTracks(input, ext);
    case '.iso' when _dvdSystems.contains(game.system):
      format = ConvertFormat.chd;
      dvd = true;
    case '.iso' || '.gcm' || '.wbfs' when rvzSystems.contains(game.system):
      format = ConvertFormat.rvz;
    default:
      return null;
  }
  final folder = p.dirname(input.path);
  final seen = <String>{};
  final originals = <File>[];
  for (final path in [input.path, ...tracks.map((t) => p.join(folder, t))]) {
    if (seen.add(p.normalize(path))) originals.add(File(path));
  }
  final base = p.basenameWithoutExtension(input.path);
  final out = format.name;
  return ConversionPlan(
    format: format,
    dvd: dvd,
    input: input,
    originals: originals,
    output: File(p.join(folder, '$base.$out')),
    part: File(p.join(folder, '.$base.$out.part')),
  );
}

List<String> _readTracks(File sheet, String ext) {
  final String text;
  try {
    text = sheet.readAsStringSync(
      encoding: const Utf8Codec(allowMalformed: true),
    );
  } on FileSystemException {
    return const [];
  }
  return switch (ext) {
    '.cue' => cueTracks(text),
    '.gdi' => gdiTracks(text),
    _ => _tocTracks(text),
  };
}

final _cueQuoted = RegExp(r'^\s*FILE\s+"([^"]*)"', caseSensitive: false);
final _cueBare = RegExp(r'^\s*FILE\s+(.+?)\s+\S+\s*$', caseSensitive: false);

/// Track file names in a cue sheet (`FILE "name.bin" BINARY`, quoted or not).
List<String> cueTracks(String text) => [
  for (final line in const LineSplitter().convert(text))
    if ((_cueQuoted.firstMatch(line) ?? _cueBare.firstMatch(line))
        case final m?)
      m.group(1)!,
];

final _gdiQuoted = RegExp(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+"([^"]*)"');
final _gdiBare = RegExp(r'^\s*\d+\s+\d+\s+\d+\s+\d+\s+(.+?)\s+-?\d+\s*$');

/// Track file names in a `.gdi` (lines `N lba type sector "name" offset`,
/// the name quoted or not).
List<String> gdiTracks(String text) => [
  for (final line in const LineSplitter().convert(text))
    if ((_gdiQuoted.firstMatch(line) ?? _gdiBare.firstMatch(line))
        case final m?)
      m.group(1)!,
];

final _tocFile = RegExp(r'^\s*(?:DATA)?FILE\s+"([^"]*)"', caseSensitive: false);

/// Track file names in a cdrdao `.toc` (`FILE "name.bin" ...` /
/// `DATAFILE "name.bin" ...`).
List<String> _tocTracks(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (_tocFile.firstMatch(line) case final m?) m.group(1)!,
];

final _percent = RegExp(r'(\d+(?:\.\d+)?)\s*%');

/// The first percentage in a tool's progress line (`Compressing, 45.2%
/// complete... (ratio=40.1%)`, `Verifying, 12.0% complete...`, DolphinTool's
/// `NN%`) as 0..1, or null when the line has none.
double? parseProgress(String line) {
  final m = _percent.firstMatch(line);
  if (m == null) return null;
  return (double.parse(m.group(1)!) / 100).clamp(0.0, 1.0);
}

/// Finds the conversion tools, which are not bundled.
class ToolLocator {
  ToolLocator({
    Map<String, String>? environment,
    String? appDir,
    this.dataDir,
    bool? windows,
    bool Function(String path)? exists,
  }) : environment = environment ?? Platform.environment,
       appDir = appDir ?? p.dirname(Platform.resolvedExecutable),
       windows = windows ?? Platform.isWindows,
       _exists = exists ?? ((path) => File(path).existsSync());

  final Map<String, String> environment;

  /// The app's own folder (`<appDir>/tools/` is searched).
  final String appDir;

  /// The app's data folder (`<dataDir>/tools/` is searched), if known.
  final String? dataDir;
  final bool windows;
  final bool Function(String path) _exists;

  /// Path of `chdman` or `dolphintool`, or null when it isn't installed.
  /// Order: env `DENA_CHDMAN` / `DENA_DOLPHINTOOL`; `<appDir>/tools/`;
  /// `<dataDir>/tools/`; each `PATH` entry.
  String? find(String tool) {
    final ctx = p.Context(style: windows ? p.Style.windows : p.Style.posix);
    final env = environment['DENA_${tool.toUpperCase()}'];
    if (env != null && env.isNotEmpty && _exists(env)) return env;
    final names = _names(tool);
    final dirs = [
      ctx.join(appDir, 'tools'),
      if (dataDir case final d?) ctx.join(d, 'tools'),
      ...?environment['PATH']
          ?.split(windows ? ';' : ':')
          .where((e) => e.isNotEmpty),
    ];
    for (final dir in dirs) {
      for (final name in names) {
        final path = ctx.join(dir, name);
        if (_exists(path)) return path;
      }
    }
    return null;
  }

  List<String> _names(String tool) {
    final names = switch (tool) {
      'chdman' => ['chdman'],
      'dolphintool' => ['dolphin-tool', 'DolphinTool'],
      _ => [tool],
    };
    return windows ? [for (final n in names) '$n.exe'] : names;
  }
}

/// Starts a process; [Process.start] outside tests.
typedef StartProcess = Future<Process> Function(
  String executable,
  List<String> arguments,
);

enum JobState { queued, running, verifying, done, failed, cancelled }

/// One queued conversion and how far it got.
class ConversionJob {
  ConversionJob(this.game, this.plan);

  final Game game;
  final ConversionPlan plan;
  JobState state = JobState.queued;

  /// 0..1 within the current step.
  double progress = 0;

  /// Why it failed, or the space saved when done.
  String? message;

  /// Whether it is still waiting or running.
  bool get active =>
      state == JobState.queued ||
      state == JobState.running ||
      state == JobState.verifying;

  Process? _process;

  /// Past verification: renaming and updating the library, no longer
  /// cancellable.
  bool _finishing = false;
}

bool _never() => false;

/// Runs conversions one at a time, in the order they were queued.
class ConversionQueue extends ChangeNotifier {
  ConversionQueue({
    required this.tools,
    required this.onConverted,
    this.start = Process.start,
    this.keepOriginals = _never,
  });

  final ToolLocator tools;

  /// Called after the output is verified and renamed into place, before the
  /// originals are deleted; points the library at it (see [pointGameAt]). If
  /// it throws, the job fails, the output is removed and the originals stay.
  final Future<void> Function(Game game, File output) onConverted;
  final StartProcess start;

  /// KEEP ORIGINALS, read when a job finishes.
  final bool Function() keepOriginals;

  final _jobs = <ConversionJob>[];
  bool _running = false;
  bool _disposed = false;

  List<ConversionJob> get jobs => List.unmodifiable(_jobs);

  /// Whether a job is queued or running.
  bool get busy => _jobs.any((j) => j.active);

  /// Why [game] can't be queued (`Not a format that converts`, `chdman not
  /// found`, `Already queued`), or null.
  String? problemFor(Game game) {
    final plan = planFor(game);
    if (plan == null) return 'Not a format that converts';
    if (_jobs.any((j) => j.active && j.game.id == game.id)) {
      return 'Already queued';
    }
    if (tools.find(plan.tool) == null) return '${plan.tool} not found';
    return null;
  }

  /// Queues [game]; returns null and does nothing when [problemFor] isn't
  /// null.
  ConversionJob? enqueue(Game game) {
    if (problemFor(game) != null) return null;
    final job = ConversionJob(game, planFor(game)!);
    _jobs.add(job);
    _notify();
    unawaited(_pump());
    return job;
  }

  /// Stops [job]: kills its process (a queued job just becomes cancelled)
  /// and deletes the part file.
  void cancel(ConversionJob job) {
    if (!job.active || job._finishing) return;
    job.state = JobState.cancelled;
    job.message = 'Cancelled';
    job._process?.kill();
    _deletePart(job);
    _notify();
  }

  /// Drops finished, failed and cancelled jobs from [jobs].
  void clearFinished() {
    _jobs.removeWhere((j) => !j.active);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final j in _jobs) {
      j._process?.kill();
    }
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (!_disposed) {
        final next = _jobs.where((j) => j.state == JobState.queued).firstOrNull;
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _run(ConversionJob job) async {
    final plan = job.plan;
    try {
      job.state = JobState.running;
      job.progress = 0;
      _notify();
      if (plan.output.existsSync()) {
        return _fail(job, '${p.basename(plan.output.path)} already exists');
      }
      final tool = tools.find(plan.tool);
      if (tool == null) return _fail(job, '${plan.tool} not found');
      final before = _totalSize(plan.originals);

      var (code, last) = await _step(job, tool, plan.convertArgs);
      if (job.state == JobState.cancelled) return _deletePart(job);
      if (code != 0) return _fail(job, last ?? '${plan.tool} exited $code');

      job.state = JobState.verifying;
      job.progress = 0;
      _notify();
      (code, last) = await _step(job, tool, plan.verifyArgs);
      if (job.state == JobState.cancelled) return _deletePart(job);
      if (code != 0) {
        return _fail(job, 'Verification failed: ${last ?? 'exit $code'}');
      }

      job._finishing = true;
      await plan.part.rename(plan.output.path);
      try {
        await onConverted(job.game, plan.output);
      } catch (_) {
        await _deleteQuietly(plan.output);
        rethrow;
      }
      if (!keepOriginals()) {
        for (final f in plan.originals) {
          await _deleteQuietly(f);
        }
      }
      final saved = before - plan.output.lengthSync();
      job.state = JobState.done;
      job.progress = 1;
      job.message = saved > 0 ? 'Saved ${_size(saved)}' : 'Converted';
      _notify();
    } catch (e) {
      _fail(job, '$e');
    }
  }

  /// Runs [tool] for the current step of [job]; returns the exit code and
  /// the last non-empty output line.
  Future<(int, String?)> _step(
    ConversionJob job,
    String tool,
    List<String> args,
  ) async {
    final process = await start(tool, args);
    job._process = process;
    if (job.state == JobState.cancelled) process.kill();
    String? last;
    var shown = job.progress;
    void onLine(String line) {
      final text = line.trim();
      if (text.isEmpty) return;
      last = text;
      final value = parseProgress(text);
      if (value == null || job.state == JobState.cancelled) return;
      job.progress = value;
      if ((value - shown).abs() >= 0.005) {
        shown = value;
        _notify();
      }
    }

    try {
      final results = await Future.wait([
        process.exitCode,
        _lines(process.stdout, onLine),
        _lines(process.stderr, onLine),
      ]);
      return (results[0], last);
    } finally {
      job._process = null;
    }
  }

  void _fail(ConversionJob job, String message) {
    job.state = JobState.failed;
    job.message = message;
    _deletePart(job);
    _notify();
  }

  void _deletePart(ConversionJob job) {
    try {
      if (job.plan.part.existsSync()) job.plan.part.deleteSync();
    } on FileSystemException {
      // Gone already or still held open; nothing else to do.
    }
  }
}

/// Feeds [stream]'s lines, split on both `\r` and `\n`, to [onLine]; returns
/// 0 when it closes.
Future<int> _lines(Stream<List<int>> stream, void Function(String) onLine) {
  var buffer = '';
  final done = Completer<int>();
  stream
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
        (chunk) {
          final parts = (buffer + chunk).split(RegExp('[\r\n]'));
          buffer = parts.removeLast();
          parts.forEach(onLine);
        },
        onError: (_) {},
        onDone: () {
          onLine(buffer);
          done.complete(0);
        },
        cancelOnError: false,
      );
  return done.future;
}

int _totalSize(List<File> files) {
  var total = 0;
  for (final f in files) {
    if (f.existsSync()) total += f.lengthSync();
  }
  return total;
}

String _size(int bytes) => bytes >= 1 << 20
    ? '${(bytes / (1 << 20)).round()} MB'
    : '${(bytes / 1024).ceil()} KB';

Future<void> _deleteQuietly(File f) async {
  try {
    await f.delete();
  } on FileSystemException {
    // Missing tracks are fine.
  }
}

/// Points [game]'s library row at [output] (path, file name, size); the
/// SHA-1, and with it saves, states, art and the verify result, stays.
Future<void> pointGameAt(LibraryDatabase db, Game game, File output) =>
    db.customUpdate(
      'UPDATE games SET path = ?, file_name = ?, size = ? WHERE id = ?',
      variables: [
        Variable(output.path),
        Variable(p.basename(output.path)),
        Variable(output.lengthSync()),
        Variable(game.id),
      ],
      updates: {db.games},
    );
