// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'controller_profiles.dart';

// ignore_for_file: type=lint
class $ControllerProfilesTable extends ControllerProfiles
    with TableInfo<$ControllerProfilesTable, ControllerProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ControllerProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _controllerMeta = const VerificationMeta(
    'controller',
  );
  @override
  late final GeneratedColumn<String> controller = GeneratedColumn<String>(
    'controller',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _controllerNameMeta = const VerificationMeta(
    'controllerName',
  );
  @override
  late final GeneratedColumn<String> controllerName = GeneratedColumn<String>(
    'controller_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _gameMeta = const VerificationMeta('game');
  @override
  late final GeneratedColumn<String> game = GeneratedColumn<String>(
    'game',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _gameTitleMeta = const VerificationMeta(
    'gameTitle',
  );
  @override
  late final GeneratedColumn<String> gameTitle = GeneratedColumn<String>(
    'game_title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _buttonsMeta = const VerificationMeta(
    'buttons',
  );
  @override
  late final GeneratedColumn<String> buttons = GeneratedColumn<String>(
    'buttons',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _gyroMeta = const VerificationMeta('gyro');
  @override
  late final GeneratedColumn<int> gyro = GeneratedColumn<int>(
    'gyro',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sensitivityMeta = const VerificationMeta(
    'sensitivity',
  );
  @override
  late final GeneratedColumn<int> sensitivity = GeneratedColumn<int>(
    'sensitivity',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(100),
  );
  static const VerificationMeta _deadzoneMeta = const VerificationMeta(
    'deadzone',
  );
  @override
  late final GeneratedColumn<int> deadzone = GeneratedColumn<int>(
    'deadzone',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(150),
  );
  static const VerificationMeta _invertYMeta = const VerificationMeta(
    'invertY',
  );
  @override
  late final GeneratedColumn<bool> invertY = GeneratedColumn<bool>(
    'invert_y',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("invert_y" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    controller,
    controllerName,
    game,
    gameTitle,
    buttons,
    gyro,
    sensitivity,
    deadzone,
    invertY,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'controller_profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<ControllerProfileRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('controller')) {
      context.handle(
        _controllerMeta,
        controller.isAcceptableOrUnknown(data['controller']!, _controllerMeta),
      );
    }
    if (data.containsKey('controller_name')) {
      context.handle(
        _controllerNameMeta,
        controllerName.isAcceptableOrUnknown(
          data['controller_name']!,
          _controllerNameMeta,
        ),
      );
    }
    if (data.containsKey('game')) {
      context.handle(
        _gameMeta,
        game.isAcceptableOrUnknown(data['game']!, _gameMeta),
      );
    }
    if (data.containsKey('game_title')) {
      context.handle(
        _gameTitleMeta,
        gameTitle.isAcceptableOrUnknown(data['game_title']!, _gameTitleMeta),
      );
    }
    if (data.containsKey('buttons')) {
      context.handle(
        _buttonsMeta,
        buttons.isAcceptableOrUnknown(data['buttons']!, _buttonsMeta),
      );
    } else if (isInserting) {
      context.missing(_buttonsMeta);
    }
    if (data.containsKey('gyro')) {
      context.handle(
        _gyroMeta,
        gyro.isAcceptableOrUnknown(data['gyro']!, _gyroMeta),
      );
    }
    if (data.containsKey('sensitivity')) {
      context.handle(
        _sensitivityMeta,
        sensitivity.isAcceptableOrUnknown(
          data['sensitivity']!,
          _sensitivityMeta,
        ),
      );
    }
    if (data.containsKey('deadzone')) {
      context.handle(
        _deadzoneMeta,
        deadzone.isAcceptableOrUnknown(data['deadzone']!, _deadzoneMeta),
      );
    }
    if (data.containsKey('invert_y')) {
      context.handle(
        _invertYMeta,
        invertY.isAcceptableOrUnknown(data['invert_y']!, _invertYMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {controller, game},
  ];
  @override
  ControllerProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ControllerProfileRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      controller: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}controller'],
      )!,
      controllerName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}controller_name'],
      )!,
      game: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}game'],
      )!,
      gameTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}game_title'],
      )!,
      buttons: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}buttons'],
      )!,
      gyro: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}gyro'],
      )!,
      sensitivity: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sensitivity'],
      )!,
      deadzone: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deadzone'],
      )!,
      invertY: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}invert_y'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ControllerProfilesTable createAlias(String alias) {
    return $ControllerProfilesTable(attachedDatabase, alias);
  }
}

class ControllerProfileRow extends DataClass
    implements Insertable<ControllerProfileRow> {
  final int id;

  /// SDL GUID, '' for any controller.
  final String controller;
  final String controllerName;

  /// Game SHA-1, '' for any game.
  final String game;
  final String gameTitle;

  /// 16 comma-separated targets.
  final String buttons;
  final int gyro;

  /// Hundredths.
  final int sensitivity;
  final int deadzone;
  final bool invertY;
  final DateTime updatedAt;
  const ControllerProfileRow({
    required this.id,
    required this.controller,
    required this.controllerName,
    required this.game,
    required this.gameTitle,
    required this.buttons,
    required this.gyro,
    required this.sensitivity,
    required this.deadzone,
    required this.invertY,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['controller'] = Variable<String>(controller);
    map['controller_name'] = Variable<String>(controllerName);
    map['game'] = Variable<String>(game);
    map['game_title'] = Variable<String>(gameTitle);
    map['buttons'] = Variable<String>(buttons);
    map['gyro'] = Variable<int>(gyro);
    map['sensitivity'] = Variable<int>(sensitivity);
    map['deadzone'] = Variable<int>(deadzone);
    map['invert_y'] = Variable<bool>(invertY);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ControllerProfilesCompanion toCompanion(bool nullToAbsent) {
    return ControllerProfilesCompanion(
      id: Value(id),
      controller: Value(controller),
      controllerName: Value(controllerName),
      game: Value(game),
      gameTitle: Value(gameTitle),
      buttons: Value(buttons),
      gyro: Value(gyro),
      sensitivity: Value(sensitivity),
      deadzone: Value(deadzone),
      invertY: Value(invertY),
      updatedAt: Value(updatedAt),
    );
  }

  factory ControllerProfileRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ControllerProfileRow(
      id: serializer.fromJson<int>(json['id']),
      controller: serializer.fromJson<String>(json['controller']),
      controllerName: serializer.fromJson<String>(json['controllerName']),
      game: serializer.fromJson<String>(json['game']),
      gameTitle: serializer.fromJson<String>(json['gameTitle']),
      buttons: serializer.fromJson<String>(json['buttons']),
      gyro: serializer.fromJson<int>(json['gyro']),
      sensitivity: serializer.fromJson<int>(json['sensitivity']),
      deadzone: serializer.fromJson<int>(json['deadzone']),
      invertY: serializer.fromJson<bool>(json['invertY']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'controller': serializer.toJson<String>(controller),
      'controllerName': serializer.toJson<String>(controllerName),
      'game': serializer.toJson<String>(game),
      'gameTitle': serializer.toJson<String>(gameTitle),
      'buttons': serializer.toJson<String>(buttons),
      'gyro': serializer.toJson<int>(gyro),
      'sensitivity': serializer.toJson<int>(sensitivity),
      'deadzone': serializer.toJson<int>(deadzone),
      'invertY': serializer.toJson<bool>(invertY),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ControllerProfileRow copyWith({
    int? id,
    String? controller,
    String? controllerName,
    String? game,
    String? gameTitle,
    String? buttons,
    int? gyro,
    int? sensitivity,
    int? deadzone,
    bool? invertY,
    DateTime? updatedAt,
  }) => ControllerProfileRow(
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
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ControllerProfileRow copyWithCompanion(ControllerProfilesCompanion data) {
    return ControllerProfileRow(
      id: data.id.present ? data.id.value : this.id,
      controller: data.controller.present
          ? data.controller.value
          : this.controller,
      controllerName: data.controllerName.present
          ? data.controllerName.value
          : this.controllerName,
      game: data.game.present ? data.game.value : this.game,
      gameTitle: data.gameTitle.present ? data.gameTitle.value : this.gameTitle,
      buttons: data.buttons.present ? data.buttons.value : this.buttons,
      gyro: data.gyro.present ? data.gyro.value : this.gyro,
      sensitivity: data.sensitivity.present
          ? data.sensitivity.value
          : this.sensitivity,
      deadzone: data.deadzone.present ? data.deadzone.value : this.deadzone,
      invertY: data.invertY.present ? data.invertY.value : this.invertY,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ControllerProfileRow(')
          ..write('id: $id, ')
          ..write('controller: $controller, ')
          ..write('controllerName: $controllerName, ')
          ..write('game: $game, ')
          ..write('gameTitle: $gameTitle, ')
          ..write('buttons: $buttons, ')
          ..write('gyro: $gyro, ')
          ..write('sensitivity: $sensitivity, ')
          ..write('deadzone: $deadzone, ')
          ..write('invertY: $invertY, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    controller,
    controllerName,
    game,
    gameTitle,
    buttons,
    gyro,
    sensitivity,
    deadzone,
    invertY,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ControllerProfileRow &&
          other.id == this.id &&
          other.controller == this.controller &&
          other.controllerName == this.controllerName &&
          other.game == this.game &&
          other.gameTitle == this.gameTitle &&
          other.buttons == this.buttons &&
          other.gyro == this.gyro &&
          other.sensitivity == this.sensitivity &&
          other.deadzone == this.deadzone &&
          other.invertY == this.invertY &&
          other.updatedAt == this.updatedAt);
}

class ControllerProfilesCompanion
    extends UpdateCompanion<ControllerProfileRow> {
  final Value<int> id;
  final Value<String> controller;
  final Value<String> controllerName;
  final Value<String> game;
  final Value<String> gameTitle;
  final Value<String> buttons;
  final Value<int> gyro;
  final Value<int> sensitivity;
  final Value<int> deadzone;
  final Value<bool> invertY;
  final Value<DateTime> updatedAt;
  const ControllerProfilesCompanion({
    this.id = const Value.absent(),
    this.controller = const Value.absent(),
    this.controllerName = const Value.absent(),
    this.game = const Value.absent(),
    this.gameTitle = const Value.absent(),
    this.buttons = const Value.absent(),
    this.gyro = const Value.absent(),
    this.sensitivity = const Value.absent(),
    this.deadzone = const Value.absent(),
    this.invertY = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  ControllerProfilesCompanion.insert({
    this.id = const Value.absent(),
    this.controller = const Value.absent(),
    this.controllerName = const Value.absent(),
    this.game = const Value.absent(),
    this.gameTitle = const Value.absent(),
    required String buttons,
    this.gyro = const Value.absent(),
    this.sensitivity = const Value.absent(),
    this.deadzone = const Value.absent(),
    this.invertY = const Value.absent(),
    required DateTime updatedAt,
  }) : buttons = Value(buttons),
       updatedAt = Value(updatedAt);
  static Insertable<ControllerProfileRow> custom({
    Expression<int>? id,
    Expression<String>? controller,
    Expression<String>? controllerName,
    Expression<String>? game,
    Expression<String>? gameTitle,
    Expression<String>? buttons,
    Expression<int>? gyro,
    Expression<int>? sensitivity,
    Expression<int>? deadzone,
    Expression<bool>? invertY,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (controller != null) 'controller': controller,
      if (controllerName != null) 'controller_name': controllerName,
      if (game != null) 'game': game,
      if (gameTitle != null) 'game_title': gameTitle,
      if (buttons != null) 'buttons': buttons,
      if (gyro != null) 'gyro': gyro,
      if (sensitivity != null) 'sensitivity': sensitivity,
      if (deadzone != null) 'deadzone': deadzone,
      if (invertY != null) 'invert_y': invertY,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  ControllerProfilesCompanion copyWith({
    Value<int>? id,
    Value<String>? controller,
    Value<String>? controllerName,
    Value<String>? game,
    Value<String>? gameTitle,
    Value<String>? buttons,
    Value<int>? gyro,
    Value<int>? sensitivity,
    Value<int>? deadzone,
    Value<bool>? invertY,
    Value<DateTime>? updatedAt,
  }) {
    return ControllerProfilesCompanion(
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
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (controller.present) {
      map['controller'] = Variable<String>(controller.value);
    }
    if (controllerName.present) {
      map['controller_name'] = Variable<String>(controllerName.value);
    }
    if (game.present) {
      map['game'] = Variable<String>(game.value);
    }
    if (gameTitle.present) {
      map['game_title'] = Variable<String>(gameTitle.value);
    }
    if (buttons.present) {
      map['buttons'] = Variable<String>(buttons.value);
    }
    if (gyro.present) {
      map['gyro'] = Variable<int>(gyro.value);
    }
    if (sensitivity.present) {
      map['sensitivity'] = Variable<int>(sensitivity.value);
    }
    if (deadzone.present) {
      map['deadzone'] = Variable<int>(deadzone.value);
    }
    if (invertY.present) {
      map['invert_y'] = Variable<bool>(invertY.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ControllerProfilesCompanion(')
          ..write('id: $id, ')
          ..write('controller: $controller, ')
          ..write('controllerName: $controllerName, ')
          ..write('game: $game, ')
          ..write('gameTitle: $gameTitle, ')
          ..write('buttons: $buttons, ')
          ..write('gyro: $gyro, ')
          ..write('sensitivity: $sensitivity, ')
          ..write('deadzone: $deadzone, ')
          ..write('invertY: $invertY, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$ProfilesDatabase extends GeneratedDatabase {
  _$ProfilesDatabase(QueryExecutor e) : super(e);
  $ProfilesDatabaseManager get managers => $ProfilesDatabaseManager(this);
  late final $ControllerProfilesTable controllerProfiles =
      $ControllerProfilesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [controllerProfiles];
}

typedef $$ControllerProfilesTableCreateCompanionBuilder =
    ControllerProfilesCompanion Function({
      Value<int> id,
      Value<String> controller,
      Value<String> controllerName,
      Value<String> game,
      Value<String> gameTitle,
      required String buttons,
      Value<int> gyro,
      Value<int> sensitivity,
      Value<int> deadzone,
      Value<bool> invertY,
      required DateTime updatedAt,
    });
typedef $$ControllerProfilesTableUpdateCompanionBuilder =
    ControllerProfilesCompanion Function({
      Value<int> id,
      Value<String> controller,
      Value<String> controllerName,
      Value<String> game,
      Value<String> gameTitle,
      Value<String> buttons,
      Value<int> gyro,
      Value<int> sensitivity,
      Value<int> deadzone,
      Value<bool> invertY,
      Value<DateTime> updatedAt,
    });

class $$ControllerProfilesTableFilterComposer
    extends Composer<_$ProfilesDatabase, $ControllerProfilesTable> {
  $$ControllerProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get controller => $composableBuilder(
    column: $table.controller,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get controllerName => $composableBuilder(
    column: $table.controllerName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get game => $composableBuilder(
    column: $table.game,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gameTitle => $composableBuilder(
    column: $table.gameTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get buttons => $composableBuilder(
    column: $table.buttons,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get gyro => $composableBuilder(
    column: $table.gyro,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sensitivity => $composableBuilder(
    column: $table.sensitivity,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deadzone => $composableBuilder(
    column: $table.deadzone,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get invertY => $composableBuilder(
    column: $table.invertY,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ControllerProfilesTableOrderingComposer
    extends Composer<_$ProfilesDatabase, $ControllerProfilesTable> {
  $$ControllerProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get controller => $composableBuilder(
    column: $table.controller,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get controllerName => $composableBuilder(
    column: $table.controllerName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get game => $composableBuilder(
    column: $table.game,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gameTitle => $composableBuilder(
    column: $table.gameTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get buttons => $composableBuilder(
    column: $table.buttons,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get gyro => $composableBuilder(
    column: $table.gyro,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sensitivity => $composableBuilder(
    column: $table.sensitivity,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deadzone => $composableBuilder(
    column: $table.deadzone,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get invertY => $composableBuilder(
    column: $table.invertY,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ControllerProfilesTableAnnotationComposer
    extends Composer<_$ProfilesDatabase, $ControllerProfilesTable> {
  $$ControllerProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get controller => $composableBuilder(
    column: $table.controller,
    builder: (column) => column,
  );

  GeneratedColumn<String> get controllerName => $composableBuilder(
    column: $table.controllerName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get game =>
      $composableBuilder(column: $table.game, builder: (column) => column);

  GeneratedColumn<String> get gameTitle =>
      $composableBuilder(column: $table.gameTitle, builder: (column) => column);

  GeneratedColumn<String> get buttons =>
      $composableBuilder(column: $table.buttons, builder: (column) => column);

  GeneratedColumn<int> get gyro =>
      $composableBuilder(column: $table.gyro, builder: (column) => column);

  GeneratedColumn<int> get sensitivity => $composableBuilder(
    column: $table.sensitivity,
    builder: (column) => column,
  );

  GeneratedColumn<int> get deadzone =>
      $composableBuilder(column: $table.deadzone, builder: (column) => column);

  GeneratedColumn<bool> get invertY =>
      $composableBuilder(column: $table.invertY, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ControllerProfilesTableTableManager
    extends
        RootTableManager<
          _$ProfilesDatabase,
          $ControllerProfilesTable,
          ControllerProfileRow,
          $$ControllerProfilesTableFilterComposer,
          $$ControllerProfilesTableOrderingComposer,
          $$ControllerProfilesTableAnnotationComposer,
          $$ControllerProfilesTableCreateCompanionBuilder,
          $$ControllerProfilesTableUpdateCompanionBuilder,
          (
            ControllerProfileRow,
            BaseReferences<
              _$ProfilesDatabase,
              $ControllerProfilesTable,
              ControllerProfileRow
            >,
          ),
          ControllerProfileRow,
          PrefetchHooks Function()
        > {
  $$ControllerProfilesTableTableManager(
    _$ProfilesDatabase db,
    $ControllerProfilesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ControllerProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ControllerProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ControllerProfilesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> controller = const Value.absent(),
                Value<String> controllerName = const Value.absent(),
                Value<String> game = const Value.absent(),
                Value<String> gameTitle = const Value.absent(),
                Value<String> buttons = const Value.absent(),
                Value<int> gyro = const Value.absent(),
                Value<int> sensitivity = const Value.absent(),
                Value<int> deadzone = const Value.absent(),
                Value<bool> invertY = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => ControllerProfilesCompanion(
                id: id,
                controller: controller,
                controllerName: controllerName,
                game: game,
                gameTitle: gameTitle,
                buttons: buttons,
                gyro: gyro,
                sensitivity: sensitivity,
                deadzone: deadzone,
                invertY: invertY,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> controller = const Value.absent(),
                Value<String> controllerName = const Value.absent(),
                Value<String> game = const Value.absent(),
                Value<String> gameTitle = const Value.absent(),
                required String buttons,
                Value<int> gyro = const Value.absent(),
                Value<int> sensitivity = const Value.absent(),
                Value<int> deadzone = const Value.absent(),
                Value<bool> invertY = const Value.absent(),
                required DateTime updatedAt,
              }) => ControllerProfilesCompanion.insert(
                id: id,
                controller: controller,
                controllerName: controllerName,
                game: game,
                gameTitle: gameTitle,
                buttons: buttons,
                gyro: gyro,
                sensitivity: sensitivity,
                deadzone: deadzone,
                invertY: invertY,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ControllerProfilesTable, ControllerProfileRow>(
                    table,
                  ),
                  BaseReferences<
                    _$ProfilesDatabase,
                    $ControllerProfilesTable,
                    ControllerProfileRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ControllerProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$ProfilesDatabase,
      $ControllerProfilesTable,
      ControllerProfileRow,
      $$ControllerProfilesTableFilterComposer,
      $$ControllerProfilesTableOrderingComposer,
      $$ControllerProfilesTableAnnotationComposer,
      $$ControllerProfilesTableCreateCompanionBuilder,
      $$ControllerProfilesTableUpdateCompanionBuilder,
      (
        ControllerProfileRow,
        BaseReferences<
          _$ProfilesDatabase,
          $ControllerProfilesTable,
          ControllerProfileRow
        >,
      ),
      ControllerProfileRow,
      PrefetchHooks Function()
    >;

class $ProfilesDatabaseManager {
  final _$ProfilesDatabase _db;
  $ProfilesDatabaseManager(this._db);
  $$ControllerProfilesTableTableManager get controllerProfiles =>
      $$ControllerProfilesTableTableManager(_db, _db.controllerProfiles);
}
