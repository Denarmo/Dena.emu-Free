// SPDX-License-Identifier: GPL-3.0-or-later
// Controller profiles (Windows and SteamOS): button remaps and gyro aiming
// per game and per controller, kept in a Drift database of their own and
// sent to the host library as text (desktop.h, dena_desktop_set_profiles).
// Spec: docs/specs/gamepads.md (Desktop: profiles and gyro)
import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../shell/host_library.dart';
import '../shell/platform_features.dart';

part 'controller_profiles.g.dart';

/// What a controller's gyro drives (pad_profile.h, GyroMode).
enum GyroMode {
  off(0, 'Off', 'No gyro'),

  /// N64 aiming (the N64 stick), the GameCube main stick.
  leftStick(1, 'L-stick', 'Adds to the left stick: N64 aiming'),

  /// Camera sticks, the N64 C-buttons, the Wii Remote's aim
  /// (gamecube-wii.md).
  rightStick(2, 'R-stick', 'Adds to the right stick: cameras, Wii aim'),

  /// DS touch screen, PSP pointer and the Wii Remote pointer (player 1,
  /// gamecube-wii.md); R3 touches.
  pointer(3, 'Pointer', 'Moves the touch pointer, R3 touches: DS, Wii');

  const GyroMode(this.hostCode, this.label, this.description);

  final int hostCode;
  final String label;
  final String description;

  static GyroMode fromHost(int code) =>
      values.firstWhere((m) => m.hostCode == code, orElse: () => off);
}

/// RetroPad buttons by bit (RETRO_DEVICE_ID_JOYPAD_*), as the remap table
/// names them.
const retroPadButtons = [
  'B', 'Y', 'Select', 'Start', 'Up', 'Down', 'Left', 'Right', //
  'A', 'X', 'L', 'R', 'L2', 'R2', 'L3', 'R3',
];

/// Every button sends itself.
const identityButtons = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

/// Gyro sensitivity choices (x full tilt at 120 deg/s, or a full sweep of
/// the pointer per 60 degrees, at 1).
const gyroSensitivities = [0.5, 1.0, 1.5, 2.0, 3.0];

/// Gyro dead zone choices, degrees a second.
const gyroDeadzones = [0.0, 1.0, 1.5, 3.0, 5.0];

/// One profile. An empty [controller] means any controller, an empty
/// [game] any game (gamepads.md, Precedence).
@immutable
class ControllerProfile {
  const ControllerProfile({
    this.id,
    this.controller = '',
    this.controllerName = '',
    this.game = '',
    this.gameTitle = '',
    this.buttons = identityButtons,
    this.gyro = GyroMode.off,
    this.sensitivity = 1.0,
    this.deadzone = 1.5,
    this.invertY = false,
  });

  /// Database row id; null before it is saved.
  final int? id;

  /// The controller's SDL GUID (one per model), '' for any.
  final String controller;
  final String controllerName;

  /// The game's SHA-1, '' for any.
  final String game;
  final String gameTitle;

  /// Target RetroPad bit per source bit, -1 for unbound; 16 entries.
  final List<int> buttons;
  final GyroMode gyro;
  final double sensitivity;
  final double deadzone;
  final bool invertY;

  bool get anyController => controller.isEmpty;
  bool get anyGame => game.isEmpty;

  /// Buttons that send something other than themselves.
  int get remapped => [
    for (var i = 0; i < 16; i++)
      if (buttons[i] != i) i,
  ].length;

  ControllerProfile copyWith({
    int? id,
    String? controller,
    String? controllerName,
    String? game,
    String? gameTitle,
    List<int>? buttons,
    GyroMode? gyro,
    double? sensitivity,
    double? deadzone,
    bool? invertY,
  }) => ControllerProfile(
    id: id ?? this.id,
    controller: controller ?? this.controller,
    controllerName: controllerName ?? this.controllerName,
    game: game ?? this.game,
    gameTitle: gameTitle ?? this.gameTitle,
    buttons: buttons ?? this.buttons,
    gyro: gyro ?? this.gyro,
    sensitivity: sensitivity ?? this.sensitivity,
    deadzone: deadzone ?? this.deadzone,
    invertY: invertY ?? this.invertY,
  );

  /// One dena_desktop_set_profiles line for [key] (a GUID or `*`).
  String hostLine(String key, {required bool pointerBottom}) =>
      '$key map=${buttons.join(',')} gyro=${gyro.hostCode} '
      'sens=${(sensitivity * 100).round()} dz=${(deadzone * 100).round()} '
      'inv=${invertY ? 1 : 0} area=${pointerBottom ? 1 : 0}';
}

/// The profile for [controller] (a GUID, '' for a pad no profile names) in
/// [game] ('' outside a game): this controller in this game, then any
/// controller in this game, then this controller in any game, then any
/// controller in any game. Null when none applies (the pad plays as is).
ControllerProfile? resolveProfile(
  Iterable<ControllerProfile> all, {
  required String controller,
  String game = '',
}) {
  ControllerProfile? find(String c, String g) {
    for (final p in all) {
      if (p.controller == c && p.game == g) return p;
    }
    return null;
  }

  return (controller.isNotEmpty && game.isNotEmpty
          ? find(controller, game)
          : null) ??
      (game.isNotEmpty ? find('', game) : null) ??
      (controller.isNotEmpty ? find(controller, '') : null) ??
      find('', '');
}

/// The host's text for [game] of [system]: a line per controller a profile
/// names, then `*` for every other pad. The DS pointer stays on the bottom
/// screen.
String profilesText(
  Iterable<ControllerProfile> all, {
  String game = '',
  String system = '',
}) {
  final bottom = system == 'nds';
  final guids = {
    for (final p in all)
      if (!p.anyController) p.controller,
  }.toList()..sort();
  final rest = resolveProfile(all, controller: '', game: game);
  return [
    for (final g in guids)
      // A controller whose own profiles don't apply here plays as `*`.
      if (resolveProfile(all, controller: g, game: game) case final p?
          when !identical(p, rest))
        p.hostLine(g, pointerBottom: bottom),
    if (rest != null) rest.hostLine('*', pointerBottom: bottom),
  ].map((l) => '$l\n').join();
}

/// A connected controller (desktop.h, dena_desktop_pads_info).
@immutable
class ConnectedPad {
  const ConnectedPad({
    required this.port,
    required this.guid,
    required this.gyro,
    required this.name,
  });

  /// 0-7, -1 while waiting for a free port.
  final int port;
  final String guid;
  final bool gyro;
  final String name;

  /// Parses dena_desktop_pads_info, sorted by port (waiting pads last).
  static List<ConnectedPad> parse(String text) {
    final pads = <ConnectedPad>[];
    for (final line in text.split('\n')) {
      final f = line.split('\t');
      if (f.length < 4) continue;
      final port = int.tryParse(f[0]);
      if (port == null || f[1].isEmpty) continue;
      pads.add(
        ConnectedPad(
          port: port,
          guid: f[1],
          gyro: f[2] == '1',
          name: f.sublist(3).join('\t'),
        ),
      );
    }
    int key(ConnectedPad p) => p.port < 0 ? 99 : p.port;
    return pads..sort((a, b) => key(a).compareTo(key(b)));
  }
}

/// The host library's side: where profiles go and which pads are there.
abstract interface class ProfilesHost {
  void setProfiles(String text);
  List<ConnectedPad> pads();
}

/// dena_host.dll / libdena_host.so; null off the desktop or with a host
/// library that predates profiles.
class FfiProfilesHost implements ProfilesHost {
  FfiProfilesHost._(this._set, this._info);

  static FfiProfilesHost? open() {
    if (shellProfile != ShellProfile.desktop) return null;
    final lib = openHostLibrary();
    if (lib == null) return null;
    try {
      return FfiProfilesHost._(
        lib.lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('dena_desktop_set_profiles'),
        lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'dena_desktop_pads_info',
        ),
      );
    } on ArgumentError {
      return null;
    }
  }

  final void Function(Pointer<Utf8>) _set;
  final Pointer<Utf8> Function() _info;

  @override
  void setProfiles(String text) {
    final s = text.toNativeUtf8();
    try {
      _set(s);
    } finally {
      malloc.free(s);
    }
  }

  @override
  List<ConnectedPad> pads() {
    final p = _info();
    return p == nullptr ? const [] : ConnectedPad.parse(p.toDartString());
  }
}

@DataClassName('ControllerProfileRow')
class ControllerProfiles extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// SDL GUID, '' for any controller.
  TextColumn get controller => text().withDefault(const Constant(''))();
  TextColumn get controllerName => text().withDefault(const Constant(''))();

  /// Game SHA-1, '' for any game.
  TextColumn get game => text().withDefault(const Constant(''))();
  TextColumn get gameTitle => text().withDefault(const Constant(''))();

  /// 16 comma-separated targets.
  TextColumn get buttons => text()();
  IntColumn get gyro => integer().withDefault(const Constant(0))();

  /// Hundredths.
  IntColumn get sensitivity => integer().withDefault(const Constant(100))();
  IntColumn get deadzone => integer().withDefault(const Constant(150))();
  BoolColumn get invertY => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {controller, game},
  ];
}

/// `controller_profiles.sqlite` in the desktop data folder: apart from the
/// library so its schema moves on its own.
@DriftDatabase(tables: [ControllerProfiles])
class ProfilesDatabase extends _$ProfilesDatabase {
  ProfilesDatabase(super.e);

  factory ProfilesDatabase.open(Directory dir) => ProfilesDatabase(
    LazyDatabase(() async {
      await dir.create(recursive: true);
      return NativeDatabase.createInBackground(
        File('${dir.path}${Platform.pathSeparator}controller_profiles.sqlite'),
      );
    }),
  );

  @override
  int get schemaVersion => 1;

  Future<List<ControllerProfile>> all() async => [
    for (final r in await select(controllerProfiles).get()) _fromRow(r),
  ];

  /// Saves [p], replacing a profile for the same controller and game.
  /// Returns its id.
  Future<int> put(ControllerProfile p) => transaction(() async {
    final entry = ControllerProfilesCompanion.insert(
      controller: Value(p.controller),
      controllerName: Value(p.controllerName),
      game: Value(p.game),
      gameTitle: Value(p.gameTitle),
      buttons: p.buttons.join(','),
      gyro: Value(p.gyro.hostCode),
      sensitivity: Value((p.sensitivity * 100).round()),
      deadzone: Value((p.deadzone * 100).round()),
      invertY: Value(p.invertY),
      updatedAt: DateTime.now(),
    );
    final id = p.id;
    // Another profile for the new controller and game gives way.
    await (delete(controllerProfiles)..where(
          (t) =>
              t.controller.equals(p.controller) &
              t.game.equals(p.game) &
              (id == null ? const Constant(true) : t.id.equals(id).not()),
        ))
        .go();
    if (id != null) {
      await (update(
        controllerProfiles,
      )..where((t) => t.id.equals(id))).write(entry);
      return id;
    }
    return into(controllerProfiles).insert(entry);
  });

  Future<void> remove(int id) =>
      (delete(controllerProfiles)..where((t) => t.id.equals(id))).go();

  static ControllerProfile _fromRow(ControllerProfileRow r) {
    final parts = r.buttons.split(',').map(int.tryParse).toList();
    final buttons = parts.length == 16 && parts.every((b) => b != null)
        ? [for (final b in parts) b!.clamp(-1, 15)]
        : identityButtons;
    return ControllerProfile(
      id: r.id,
      controller: r.controller,
      controllerName: r.controllerName,
      game: r.game,
      gameTitle: r.gameTitle,
      buttons: buttons,
      gyro: GyroMode.fromHost(r.gyro),
      sensitivity: r.sensitivity / 100,
      deadzone: r.deadzone / 100,
      invertY: r.invertY,
    );
  }
}

/// The profiles as Settings and the game see them: loaded once, every
/// change saved and sent to the host for the game playing now.
class ControllerProfileStore extends ChangeNotifier {
  ControllerProfileStore({this.db, this.host});

  final ProfilesDatabase? db;
  final ProfilesHost? host;
  List<ControllerProfile> _profiles = const [];
  String _game = '', _system = '';

  List<ControllerProfile> get profiles => _profiles;

  /// Connected controllers, none without the host library.
  List<ConnectedPad> pads() => host?.pads() ?? const [];

  Future<void> load() async {
    _profiles = await db?.all() ?? const [];
    _send();
    notifyListeners();
  }

  /// A game started ([sha1] and [system]) or ended (both '').
  void applyGame(String sha1, String system) {
    _game = sha1;
    _system = system;
    _send();
  }

  /// Saves [p] (new, or edited by id) and returns it with its id.
  Future<ControllerProfile> save(ControllerProfile p) async {
    final d = db;
    final saved = d == null
        ? p.copyWith(id: p.id ?? _profiles.length + 1)
        : p.copyWith(id: await d.put(p));
    _profiles = [
      for (final o in _profiles)
        if (o.id != saved.id &&
            !(o.controller == saved.controller && o.game == saved.game))
          o,
      saved,
    ];
    _send();
    notifyListeners();
    return saved;
  }

  Future<void> remove(ControllerProfile p) async {
    final id = p.id;
    if (id == null) return;
    await db?.remove(id);
    _profiles = [
      for (final o in _profiles)
        if (o.id != id) o,
    ];
    _send();
    notifyListeners();
  }

  void _send() =>
      host?.setProfiles(profilesText(_profiles, game: _game, system: _system));
}
