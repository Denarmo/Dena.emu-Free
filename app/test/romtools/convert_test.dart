// SPDX-License-Identifier: GPL-3.0-or-later
// Conversion plans, tool lookup and the job queue with a fake process.
// Spec: docs/specs/rom-manager.md (3, acceptance test 4)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dena_emu/src/library/database.dart';
import 'package:dena_emu/src/romtools/convert.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Game _game(String path, {String system = 'psx', int id = 1}) => Game(
  id: id,
  system: system,
  title: p.basenameWithoutExtension(path),
  searchTitle: p.basenameWithoutExtension(path).toLowerCase(),
  fileName: p.basename(path),
  path: path,
  sha1: 'sha$id',
  size: 0,
  crc32: '00000000',
  addedAt: DateTime(2026),
  playSeconds: 0,
  favorite: false,
);

/// A process the test drives by hand.
class FakeProcess implements Process {
  FakeProcess(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  void say(String text, {bool err = false}) =>
      (err ? _err : _out).add(utf8.encode(text));

  void finish(int code) {
    if (_exit.isCompleted) return;
    _out.close();
    _err.close();
    _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(-9);
    return true;
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('convert_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String name, [String content = 'data']) {
    final f = File(p.join(dir.path, name))..writeAsStringSync(content);
    return f.path;
  }

  group('planFor', () {
    test('cue with two tracks makes a CD CHD', () {
      final cue = write(
        'Game.cue',
        'FILE "Game (Track 1).bin" BINARY\n  TRACK 01 MODE2/2352\n'
            'FILE "Game (Track 2).bin" BINARY\n  TRACK 02 AUDIO\n'
            'FILE "Game (Track 1).bin" BINARY\n',
      );
      final plan = planFor(_game(cue))!;
      expect(plan.format, ConvertFormat.chd);
      expect(plan.tool, 'chdman');
      expect(plan.input.path, cue);
      expect(plan.originals.map((f) => p.basename(f.path)), [
        'Game.cue',
        'Game (Track 1).bin',
        'Game (Track 2).bin',
      ]);
      expect(plan.output.path, p.join(dir.path, 'Game.chd'));
      expect(plan.part.path, p.join(dir.path, '.Game.chd.part'));
      expect(plan.convertArgs, [
        'createcd',
        '-i',
        cue,
        '-o',
        plan.part.path,
        '-f',
      ]);
      expect(plan.verifyArgs, ['verify', '-i', plan.part.path]);
    });

    test('gdi lists its tracks', () {
      final gdi = write(
        'disc.gdi',
        '3\n1 0 4 2352 track01.bin 0\n2 756 0 2352 "track 02.raw" 0\n'
            '3 45000 4 2352 track03.bin 0\n',
      );
      final plan = planFor(_game(gdi, system: 'dreamcast'))!;
      expect(plan.convertArgs.first, 'createcd');
      expect(plan.originals.map((f) => p.basename(f.path)), [
        'disc.gdi',
        'track01.bin',
        'track 02.raw',
        'track03.bin',
      ]);
    });

    test('a missing cue still plans with just itself', () {
      final plan = planFor(_game(p.join(dir.path, 'gone.cue')))!;
      expect(plan.originals.map((f) => p.basename(f.path)), ['gone.cue']);
    });

    test('psp iso makes a DVD CHD', () {
      final iso = write('Game.iso');
      final plan = planFor(_game(iso, system: 'psp'))!;
      expect(plan.format, ConvertFormat.chd);
      expect(plan.convertArgs.first, 'createdvd');
      expect(plan.originals.map((f) => f.path), [iso]);
    });

    test('iso for an RVZ system makes RVZ', () {
      final iso = write('Game.iso');
      final plan = planFor(_game(iso, system: 'gamecube'))!;
      expect(plan.format, ConvertFormat.rvz);
      expect(plan.tool, 'dolphintool');
      expect(plan.output.path, p.join(dir.path, 'Game.rvz'));
      expect(plan.part.path, p.join(dir.path, '.Game.rvz.part'));
      expect(plan.convertArgs, [
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
        iso,
        '-o',
        plan.part.path,
      ]);
      expect(
        planFor(_game(write('g.wbfs'), system: 'wii'))!.format,
        ConvertFormat.rvz,
      );
    });

    test('compressed, cartridge and unknown-system files do not convert', () {
      expect(planFor(_game(write('a.chd'))), isNull);
      expect(planFor(_game(write('a.cso'), system: 'psp')), isNull);
      expect(planFor(_game(write('a.pbp'))), isNull);
      expect(planFor(_game(write('a.rvz'), system: 'wii')), isNull);
      expect(planFor(_game(write('a.gba'), system: 'gba')), isNull);
      expect(planFor(_game(write('b.iso'), system: 'psx')), isNull);
      expect(planFor(_game(write('a.gcm'), system: 'psp')), isNull);
    });
  });

  test('cueTracks reads quoted and bare names', () {
    expect(
      cueTracks(
        'REM x\r\nFILE "A B.bin" BINARY\r\n  TRACK 01 MODE1/2352\r\n'
        'file track2.bin BINARY\r\nFILE name with space.wav WAVE\r\n',
      ),
      ['A B.bin', 'track2.bin', 'name with space.wav'],
    );
  });

  test('gdiTracks reads quoted and bare names', () {
    expect(
      gdiTracks('2\n1 0 4 2352 "a b.bin" 0\n2 600 0 2352 track02.raw 0\n'),
      ['a b.bin', 'track02.raw'],
    );
  });

  test('parseProgress', () {
    expect(
      parseProgress('Compressing, 45.2% complete... (ratio=40.1%)'),
      closeTo(0.452, 1e-9),
    );
    expect(parseProgress('Verifying, 12.0% complete...'), closeTo(0.12, 1e-9));
    expect(parseProgress('  73%'), closeTo(0.73, 1e-9));
    expect(parseProgress('Compression complete ... final ratio = 40%'), 0.4);
    expect(parseProgress('Input tracks: 2'), isNull);
    expect(parseProgress(''), isNull);
  });

  group('ToolLocator', () {
    test('order: env, app folder, data folder, PATH', () {
      final present = <String>{
        '/env/chdman',
        '/app/tools/chdman',
        '/data/tools/chdman',
        '/usr/bin/chdman',
      };
      ToolLocator make(Map<String, String> env) => ToolLocator(
        environment: env,
        appDir: '/app',
        dataDir: '/data',
        windows: false,
        exists: present.contains,
      );
      const path = {'PATH': '/bin:/usr/bin'};
      expect(
        make({...path, 'DENA_CHDMAN': '/env/chdman'}).find('chdman'),
        '/env/chdman',
      );
      expect(
        make({...path, 'DENA_CHDMAN': '/nope'}).find('chdman'),
        '/app/tools/chdman',
      );
      present.remove('/app/tools/chdman');
      expect(make(path).find('chdman'), '/data/tools/chdman');
      present.remove('/data/tools/chdman');
      expect(make(path).find('chdman'), '/usr/bin/chdman');
      present.remove('/usr/bin/chdman');
      expect(make(path).find('chdman'), isNull);
    });

    test('dolphin-tool names on Linux', () {
      final t = ToolLocator(
        environment: {'PATH': '/opt/a:/opt/b'},
        appDir: '/app',
        windows: false,
        exists: {'/opt/b/DolphinTool'}.contains,
      );
      expect(t.find('dolphintool'), '/opt/b/DolphinTool');
    });

    test('Windows names and separator', () {
      final present = {r'C:\Tools\chdman.exe', r'C:\Dolphin\DolphinTool.exe'};
      final t = ToolLocator(
        environment: {'PATH': r'C:\Windows;C:\Tools;C:\Dolphin'},
        appDir: r'C:\Dena',
        dataDir: r'C:\Users\me\Dena',
        windows: true,
        exists: present.contains,
      );
      expect(t.find('chdman'), r'C:\Tools\chdman.exe');
      expect(t.find('dolphintool'), r'C:\Dolphin\DolphinTool.exe');
      present.add(r'C:\Users\me\Dena\tools\chdman.exe');
      expect(t.find('chdman'), r'C:\Users\me\Dena\tools\chdman.exe');
      present.add(r'C:\Dena\tools\dolphin-tool.exe');
      expect(t.find('dolphintool'), r'C:\Dena\tools\dolphin-tool.exe');
    });
  });

  group('ConversionQueue', () {
    late List<FakeProcess> started;
    late List<(Game, String)> converted;
    late bool keep;
    late Object? convertError;

    setUp(() {
      started = [];
      converted = [];
      keep = false;
      convertError = null;
    });

    ConversionQueue makeQueue({bool toolFound = true}) => ConversionQueue(
      tools: ToolLocator(
        environment: const {},
        appDir: '/app',
        windows: false,
        exists: (path) => toolFound && path == '/app/tools/chdman',
      ),
      onConverted: (game, output) async {
        if (convertError case final e?) throw e;
        converted.add((game, output.path));
      },
      start: (exe, args) async {
        final proc = FakeProcess(exe, args);
        if (args.first != 'verify') {
          File(args[args.indexOf('-o') + 1]).writeAsStringSync('chd');
        }
        started.add(proc);
        return proc;
      },
      keepOriginals: () => keep,
    );

    /// A cue with two tracks of 1 MiB each.
    Game cueGame({String name = 'Game', int id = 1}) {
      final cue = write(
        '$name.cue',
        'FILE "$name 1.bin" BINARY\nFILE "$name 2.bin" BINARY\n',
      );
      for (final t in ['$name 1.bin', '$name 2.bin']) {
        File(p.join(dir.path, t)).writeAsBytesSync(List.filled(1 << 20, 0));
      }
      return _game(cue, id: id);
    }

    List<String> files() =>
        dir.listSync().map((e) => p.basename(e.path)).toList()..sort();

    test(
      'success renames, calls onConverted and deletes cue and tracks',
      () async {
        final q = makeQueue();
        final game = cueGame();
        final job = q.enqueue(game)!;
        await pumpEventQueue();
        expect(job.state, JobState.running);
        expect(started.single.executable, '/app/tools/chdman');
        expect(started.single.arguments.first, 'createcd');
        expect(files(), contains('.Game.chd.part'));
        started.single.finish(0);
        await pumpEventQueue();
        expect(job.state, JobState.verifying);
        expect(started.last.arguments, [
          'verify',
          '-i',
          p.join(dir.path, '.Game.chd.part'),
        ]);
        started.last.finish(0);
        await leaveVerifying(job);
        expect(job.state, JobState.done);
        expect(job.message, 'Saved 2 MB');
        expect(converted.single.$1, game);
        expect(converted.single.$2, p.join(dir.path, 'Game.chd'));
        expect(files(), ['Game.chd']);
        expect(q.busy, isFalse);
      },
    );

    test('KEEP ORIGINALS leaves the cue and tracks', () async {
      keep = true;
      final q = makeQueue();
      final job = q.enqueue(cueGame())!;
      await pumpEventQueue();
      started.last.finish(0);
      await pumpEventQueue();
      started.last.finish(0);
      await leaveVerifying(job);
      expect(job.state, JobState.done);
      expect(files(), ['Game 1.bin', 'Game 2.bin', 'Game.chd', 'Game.cue']);
    });

    test('convert failure deletes the part and keeps the last line', () async {
      final q = makeQueue();
      final job = q.enqueue(cueGame())!;
      await pumpEventQueue();
      started.single
        ..say('Compressing, 10.0% complete...\r')
        ..say('Error: file not found\n\n', err: true)
        ..finish(1);
      await pumpEventQueue();
      expect(job.state, JobState.failed);
      expect(job.message, 'Error: file not found');
      expect(started, hasLength(1));
      expect(files(), ['Game 1.bin', 'Game 2.bin', 'Game.cue']);
      expect(converted, isEmpty);
    });

    test('verify failure keeps originals and deletes the part', () async {
      final q = makeQueue();
      final job = q.enqueue(cueGame())!;
      await pumpEventQueue();
      started.last.finish(0);
      await pumpEventQueue();
      started.last
        ..say('Error: hash mismatch\n')
        ..finish(1);
      await pumpEventQueue();
      expect(job.state, JobState.failed);
      expect(job.message, 'Verification failed: Error: hash mismatch');
      expect(files(), ['Game 1.bin', 'Game 2.bin', 'Game.cue']);
      expect(converted, isEmpty);
    });

    test('onConverted throwing keeps the originals', () async {
      convertError = StateError('db locked');
      final q = makeQueue();
      final job = q.enqueue(cueGame())!;
      await pumpEventQueue();
      started.last.finish(0);
      await pumpEventQueue();
      started.last.finish(0);
      await leaveVerifying(job);
      expect(job.state, JobState.failed);
      expect(job.message, contains('db locked'));
      expect(files(), ['Game 1.bin', 'Game 2.bin', 'Game.cue']);
    });

    test('an existing output fails before running', () async {
      final q = makeQueue();
      final game = cueGame();
      write('Game.chd');
      final job = q.enqueue(game)!;
      await pumpEventQueue();
      expect(job.state, JobState.failed);
      expect(job.message, 'Game.chd already exists');
      expect(started, isEmpty);
    });

    test('cancel mid-run kills, deletes the part and runs the next', () async {
      final q = makeQueue();
      final a = q.enqueue(cueGame(name: 'A', id: 1))!;
      final b = q.enqueue(cueGame(name: 'B', id: 2))!;
      await pumpEventQueue();
      expect(started, hasLength(1));
      q.cancel(a);
      await pumpEventQueue();
      expect(started.first.killed, isTrue);
      expect(a.state, JobState.cancelled);
      expect(files(), isNot(contains('.A.chd.part')));
      expect(b.state, JobState.running);
      expect(started, hasLength(2));
      expect(started.last.arguments[2], p.join(dir.path, 'B.cue'));
      // A queued job just becomes cancelled.
      final c = q.enqueue(cueGame(name: 'C', id: 3))!;
      q.cancel(c);
      expect(c.state, JobState.cancelled);
      q.cancel(b);
      await pumpEventQueue();
      expect(started, hasLength(2));
      expect(q.busy, isFalse);
      expect(files(), isNot(contains('.B.chd.part')));
      q.clearFinished();
      expect(q.jobs, isEmpty);
    });

    test('cancel during verify keeps the originals', () async {
      final q = makeQueue();
      final job = q.enqueue(cueGame())!;
      await pumpEventQueue();
      started.last.finish(0);
      await pumpEventQueue();
      expect(job.state, JobState.verifying);
      q.cancel(job);
      await pumpEventQueue();
      expect(job.state, JobState.cancelled);
      expect(started.last.killed, isTrue);
      expect(files(), ['Game 1.bin', 'Game 2.bin', 'Game.cue']);
      expect(converted, isEmpty);
    });

    test('jobs run one at a time in order', () async {
      final q = makeQueue();
      final a = q.enqueue(cueGame(name: 'A', id: 1))!;
      final b = q.enqueue(cueGame(name: 'B', id: 2))!;
      await pumpEventQueue();
      expect(started, hasLength(1));
      expect(b.state, JobState.queued);
      expect(q.busy, isTrue);
      started.last.finish(0);
      await pumpEventQueue();
      started.last.finish(0);
      await leaveVerifying(a);
      expect(a.state, JobState.done);
      expect(b.state, JobState.running);
      expect(started, hasLength(3));
      expect(started.last.arguments[2], p.join(dir.path, 'B.cue'));
    });

    test('progress updates are throttled', () async {
      final q = makeQueue();
      var notes = 0;
      q.addListener(() => notes++);
      final job = q.enqueue(cueGame())!;
      await pumpEventQueue();
      final base = notes;
      started.last.say(
        'Compressing, 10.0% complete...\r'
        'Compressing, 10.2% complete...\r'
        'Compressing, 10.4% complete...\r'
        'Compressing, 45.2% complete... (ratio=40.1%)\r',
      );
      await pumpEventQueue();
      expect(job.progress, closeTo(0.452, 1e-9));
      expect(notes - base, 2);
      started.last.finish(0);
      await pumpEventQueue();
      expect(job.state, JobState.verifying);
      expect(job.progress, 0);
      started.last.say('Verifying, 50.0% complete...\n');
      await pumpEventQueue();
      expect(job.progress, 0.5);
    });

    test('problemFor and enqueue refusals', () {
      final q = makeQueue();
      final cart = _game(write('a.gba'), system: 'gba');
      expect(q.problemFor(cart), 'Not a format that converts');
      expect(q.enqueue(cart), isNull);
      final game = cueGame();
      expect(makeQueue(toolFound: false).problemFor(game), 'chdman not found');
      expect(q.problemFor(game), isNull);
      q.enqueue(game);
      expect(q.problemFor(game), 'Already queued');
      expect(q.enqueue(game), isNull);
      expect(q.jobs, hasLength(1));
    });
  });

  test('pointGameAt updates path, file name and size only', () async {
    final db = LibraryDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final cue = write('Game.cue');
    final id = await db
        .into(db.games)
        .insert(
          GamesCompanion.insert(
            system: 'psx',
            title: 'Game',
            searchTitle: 'game',
            fileName: 'Game.cue',
            path: cue,
            sha1: 'abc',
            size: 10,
            crc32: '1234abcd',
            addedAt: DateTime(2026),
            favorite: const Value(true),
          ),
        );
    final game = await (db.select(
      db.games,
    )..where((g) => g.id.equals(id))).getSingle();
    final out = File(write('Game.chd', 'compressed!'));
    await pointGameAt(db, game, out);
    final after = await (db.select(
      db.games,
    )..where((g) => g.id.equals(id))).getSingle();
    expect(after.path, out.path);
    expect(after.fileName, 'Game.chd');
    expect(after.size, 11);
    expect(after.sha1, 'abc');
    expect(after.crc32, '1234abcd');
    expect(after.favorite, isTrue);
  });
}

/// Waits until [job] is past verification. Renaming the output into place is
/// real file I/O, which on Windows takes longer than [pumpEventQueue].
Future<void> leaveVerifying(ConversionJob job) async {
  for (var i = 0; i < 200 && job.state == JobState.verifying; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await pumpEventQueue();
}
