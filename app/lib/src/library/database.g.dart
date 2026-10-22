// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $GamesTable extends Games with TableInfo<$GamesTable, Game> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GamesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _systemMeta = const VerificationMeta('system');
  @override
  late final GeneratedColumn<String> system = GeneratedColumn<String>(
    'system',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _searchTitleMeta = const VerificationMeta(
    'searchTitle',
  );
  @override
  late final GeneratedColumn<String> searchTitle = GeneratedColumn<String>(
    'search_title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha1Meta = const VerificationMeta('sha1');
  @override
  late final GeneratedColumn<String> sha1 = GeneratedColumn<String>(
    'sha1',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _crc32Meta = const VerificationMeta('crc32');
  @override
  late final GeneratedColumn<String> crc32 = GeneratedColumn<String>(
    'crc32',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastPlayedAtMeta = const VerificationMeta(
    'lastPlayedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastPlayedAt = GeneratedColumn<DateTime>(
    'last_played_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _playSecondsMeta = const VerificationMeta(
    'playSeconds',
  );
  @override
  late final GeneratedColumn<int> playSeconds = GeneratedColumn<int>(
    'play_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _favoriteMeta = const VerificationMeta(
    'favorite',
  );
  @override
  late final GeneratedColumn<bool> favorite = GeneratedColumn<bool>(
    'favorite',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("favorite" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _customArtPathMeta = const VerificationMeta(
    'customArtPath',
  );
  @override
  late final GeneratedColumn<String> customArtPath = GeneratedColumn<String>(
    'custom_art_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    system,
    title,
    searchTitle,
    fileName,
    path,
    sha1,
    size,
    crc32,
    addedAt,
    lastPlayedAt,
    playSeconds,
    favorite,
    customArtPath,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'games';
  @override
  VerificationContext validateIntegrity(
    Insertable<Game> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('system')) {
      context.handle(
        _systemMeta,
        system.isAcceptableOrUnknown(data['system']!, _systemMeta),
      );
    } else if (isInserting) {
      context.missing(_systemMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('search_title')) {
      context.handle(
        _searchTitleMeta,
        searchTitle.isAcceptableOrUnknown(
          data['search_title']!,
          _searchTitleMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_searchTitleMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('sha1')) {
      context.handle(
        _sha1Meta,
        sha1.isAcceptableOrUnknown(data['sha1']!, _sha1Meta),
      );
    } else if (isInserting) {
      context.missing(_sha1Meta);
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('crc32')) {
      context.handle(
        _crc32Meta,
        crc32.isAcceptableOrUnknown(data['crc32']!, _crc32Meta),
      );
    } else if (isInserting) {
      context.missing(_crc32Meta);
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('last_played_at')) {
      context.handle(
        _lastPlayedAtMeta,
        lastPlayedAt.isAcceptableOrUnknown(
          data['last_played_at']!,
          _lastPlayedAtMeta,
        ),
      );
    }
    if (data.containsKey('play_seconds')) {
      context.handle(
        _playSecondsMeta,
        playSeconds.isAcceptableOrUnknown(
          data['play_seconds']!,
          _playSecondsMeta,
        ),
      );
    }
    if (data.containsKey('favorite')) {
      context.handle(
        _favoriteMeta,
        favorite.isAcceptableOrUnknown(data['favorite']!, _favoriteMeta),
      );
    }
    if (data.containsKey('custom_art_path')) {
      context.handle(
        _customArtPathMeta,
        customArtPath.isAcceptableOrUnknown(
          data['custom_art_path']!,
          _customArtPathMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Game map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Game(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      system: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}system'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      searchTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}search_title'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      sha1: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha1'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      crc32: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}crc32'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}added_at'],
      )!,
      lastPlayedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_played_at'],
      ),
      playSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}play_seconds'],
      )!,
      favorite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}favorite'],
      )!,
      customArtPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}custom_art_path'],
      ),
    );
  }

  @override
  $GamesTable createAlias(String alias) {
    return $GamesTable(attachedDatabase, alias);
  }
}

class Game extends DataClass implements Insertable<Game> {
  final int id;
  final String system;
  final String title;

  /// Lower-cased, diacritic-free title used for search (kept in sync by [LibraryDatabase]).
  final String searchTitle;
  final String fileName;
  final String path;
  final String sha1;
  final int size;
  final String crc32;
  final DateTime addedAt;
  final DateTime? lastPlayedAt;
  final int playSeconds;
  final bool favorite;
  final String? customArtPath;
  const Game({
    required this.id,
    required this.system,
    required this.title,
    required this.searchTitle,
    required this.fileName,
    required this.path,
    required this.sha1,
    required this.size,
    required this.crc32,
    required this.addedAt,
    this.lastPlayedAt,
    required this.playSeconds,
    required this.favorite,
    this.customArtPath,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['system'] = Variable<String>(system);
    map['title'] = Variable<String>(title);
    map['search_title'] = Variable<String>(searchTitle);
    map['file_name'] = Variable<String>(fileName);
    map['path'] = Variable<String>(path);
    map['sha1'] = Variable<String>(sha1);
    map['size'] = Variable<int>(size);
    map['crc32'] = Variable<String>(crc32);
    map['added_at'] = Variable<DateTime>(addedAt);
    if (!nullToAbsent || lastPlayedAt != null) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt);
    }
    map['play_seconds'] = Variable<int>(playSeconds);
    map['favorite'] = Variable<bool>(favorite);
    if (!nullToAbsent || customArtPath != null) {
      map['custom_art_path'] = Variable<String>(customArtPath);
    }
    return map;
  }

  GamesCompanion toCompanion(bool nullToAbsent) {
    return GamesCompanion(
      id: Value(id),
      system: Value(system),
      title: Value(title),
      searchTitle: Value(searchTitle),
      fileName: Value(fileName),
      path: Value(path),
      sha1: Value(sha1),
      size: Value(size),
      crc32: Value(crc32),
      addedAt: Value(addedAt),
      lastPlayedAt: lastPlayedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastPlayedAt),
      playSeconds: Value(playSeconds),
      favorite: Value(favorite),
      customArtPath: customArtPath == null && nullToAbsent
          ? const Value.absent()
          : Value(customArtPath),
    );
  }

  factory Game.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Game(
      id: serializer.fromJson<int>(json['id']),
      system: serializer.fromJson<String>(json['system']),
      title: serializer.fromJson<String>(json['title']),
      searchTitle: serializer.fromJson<String>(json['searchTitle']),
      fileName: serializer.fromJson<String>(json['fileName']),
      path: serializer.fromJson<String>(json['path']),
      sha1: serializer.fromJson<String>(json['sha1']),
      size: serializer.fromJson<int>(json['size']),
      crc32: serializer.fromJson<String>(json['crc32']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
      lastPlayedAt: serializer.fromJson<DateTime?>(json['lastPlayedAt']),
      playSeconds: serializer.fromJson<int>(json['playSeconds']),
      favorite: serializer.fromJson<bool>(json['favorite']),
      customArtPath: serializer.fromJson<String?>(json['customArtPath']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'system': serializer.toJson<String>(system),
      'title': serializer.toJson<String>(title),
      'searchTitle': serializer.toJson<String>(searchTitle),
      'fileName': serializer.toJson<String>(fileName),
      'path': serializer.toJson<String>(path),
      'sha1': serializer.toJson<String>(sha1),
      'size': serializer.toJson<int>(size),
      'crc32': serializer.toJson<String>(crc32),
      'addedAt': serializer.toJson<DateTime>(addedAt),
      'lastPlayedAt': serializer.toJson<DateTime?>(lastPlayedAt),
      'playSeconds': serializer.toJson<int>(playSeconds),
      'favorite': serializer.toJson<bool>(favorite),
      'customArtPath': serializer.toJson<String?>(customArtPath),
    };
  }

  Game copyWith({
    int? id,
    String? system,
    String? title,
    String? searchTitle,
    String? fileName,
    String? path,
    String? sha1,
    int? size,
    String? crc32,
    DateTime? addedAt,
    Value<DateTime?> lastPlayedAt = const Value.absent(),
    int? playSeconds,
    bool? favorite,
    Value<String?> customArtPath = const Value.absent(),
  }) => Game(
    id: id ?? this.id,
    system: system ?? this.system,
    title: title ?? this.title,
    searchTitle: searchTitle ?? this.searchTitle,
    fileName: fileName ?? this.fileName,
    path: path ?? this.path,
    sha1: sha1 ?? this.sha1,
    size: size ?? this.size,
    crc32: crc32 ?? this.crc32,
    addedAt: addedAt ?? this.addedAt,
    lastPlayedAt: lastPlayedAt.present ? lastPlayedAt.value : this.lastPlayedAt,
    playSeconds: playSeconds ?? this.playSeconds,
    favorite: favorite ?? this.favorite,
    customArtPath: customArtPath.present
        ? customArtPath.value
        : this.customArtPath,
  );
  Game copyWithCompanion(GamesCompanion data) {
    return Game(
      id: data.id.present ? data.id.value : this.id,
      system: data.system.present ? data.system.value : this.system,
      title: data.title.present ? data.title.value : this.title,
      searchTitle: data.searchTitle.present
          ? data.searchTitle.value
          : this.searchTitle,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      path: data.path.present ? data.path.value : this.path,
      sha1: data.sha1.present ? data.sha1.value : this.sha1,
      size: data.size.present ? data.size.value : this.size,
      crc32: data.crc32.present ? data.crc32.value : this.crc32,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      lastPlayedAt: data.lastPlayedAt.present
          ? data.lastPlayedAt.value
          : this.lastPlayedAt,
      playSeconds: data.playSeconds.present
          ? data.playSeconds.value
          : this.playSeconds,
      favorite: data.favorite.present ? data.favorite.value : this.favorite,
      customArtPath: data.customArtPath.present
          ? data.customArtPath.value
          : this.customArtPath,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Game(')
          ..write('id: $id, ')
          ..write('system: $system, ')
          ..write('title: $title, ')
          ..write('searchTitle: $searchTitle, ')
          ..write('fileName: $fileName, ')
          ..write('path: $path, ')
          ..write('sha1: $sha1, ')
          ..write('size: $size, ')
          ..write('crc32: $crc32, ')
          ..write('addedAt: $addedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('playSeconds: $playSeconds, ')
          ..write('favorite: $favorite, ')
          ..write('customArtPath: $customArtPath')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    system,
    title,
    searchTitle,
    fileName,
    path,
    sha1,
    size,
    crc32,
    addedAt,
    lastPlayedAt,
    playSeconds,
    favorite,
    customArtPath,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Game &&
          other.id == this.id &&
          other.system == this.system &&
          other.title == this.title &&
          other.searchTitle == this.searchTitle &&
          other.fileName == this.fileName &&
          other.path == this.path &&
          other.sha1 == this.sha1 &&
          other.size == this.size &&
          other.crc32 == this.crc32 &&
          other.addedAt == this.addedAt &&
          other.lastPlayedAt == this.lastPlayedAt &&
          other.playSeconds == this.playSeconds &&
          other.favorite == this.favorite &&
          other.customArtPath == this.customArtPath);
}

class GamesCompanion extends UpdateCompanion<Game> {
  final Value<int> id;
  final Value<String> system;
  final Value<String> title;
  final Value<String> searchTitle;
  final Value<String> fileName;
  final Value<String> path;
  final Value<String> sha1;
  final Value<int> size;
  final Value<String> crc32;
  final Value<DateTime> addedAt;
  final Value<DateTime?> lastPlayedAt;
  final Value<int> playSeconds;
  final Value<bool> favorite;
  final Value<String?> customArtPath;
  const GamesCompanion({
    this.id = const Value.absent(),
    this.system = const Value.absent(),
    this.title = const Value.absent(),
    this.searchTitle = const Value.absent(),
    this.fileName = const Value.absent(),
    this.path = const Value.absent(),
    this.sha1 = const Value.absent(),
    this.size = const Value.absent(),
    this.crc32 = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.playSeconds = const Value.absent(),
    this.favorite = const Value.absent(),
    this.customArtPath = const Value.absent(),
  });
  GamesCompanion.insert({
    this.id = const Value.absent(),
    required String system,
    required String title,
    required String searchTitle,
    required String fileName,
    required String path,
    required String sha1,
    required int size,
    required String crc32,
    required DateTime addedAt,
    this.lastPlayedAt = const Value.absent(),
    this.playSeconds = const Value.absent(),
    this.favorite = const Value.absent(),
    this.customArtPath = const Value.absent(),
  }) : system = Value(system),
       title = Value(title),
       searchTitle = Value(searchTitle),
       fileName = Value(fileName),
       path = Value(path),
       sha1 = Value(sha1),
       size = Value(size),
       crc32 = Value(crc32),
       addedAt = Value(addedAt);
  static Insertable<Game> custom({
    Expression<int>? id,
    Expression<String>? system,
    Expression<String>? title,
    Expression<String>? searchTitle,
    Expression<String>? fileName,
    Expression<String>? path,
    Expression<String>? sha1,
    Expression<int>? size,
    Expression<String>? crc32,
    Expression<DateTime>? addedAt,
    Expression<DateTime>? lastPlayedAt,
    Expression<int>? playSeconds,
    Expression<bool>? favorite,
    Expression<String>? customArtPath,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (system != null) 'system': system,
      if (title != null) 'title': title,
      if (searchTitle != null) 'search_title': searchTitle,
      if (fileName != null) 'file_name': fileName,
      if (path != null) 'path': path,
      if (sha1 != null) 'sha1': sha1,
      if (size != null) 'size': size,
      if (crc32 != null) 'crc32': crc32,
      if (addedAt != null) 'added_at': addedAt,
      if (lastPlayedAt != null) 'last_played_at': lastPlayedAt,
      if (playSeconds != null) 'play_seconds': playSeconds,
      if (favorite != null) 'favorite': favorite,
      if (customArtPath != null) 'custom_art_path': customArtPath,
    });
  }

  GamesCompanion copyWith({
    Value<int>? id,
    Value<String>? system,
    Value<String>? title,
    Value<String>? searchTitle,
    Value<String>? fileName,
    Value<String>? path,
    Value<String>? sha1,
    Value<int>? size,
    Value<String>? crc32,
    Value<DateTime>? addedAt,
    Value<DateTime?>? lastPlayedAt,
    Value<int>? playSeconds,
    Value<bool>? favorite,
    Value<String?>? customArtPath,
  }) {
    return GamesCompanion(
      id: id ?? this.id,
      system: system ?? this.system,
      title: title ?? this.title,
      searchTitle: searchTitle ?? this.searchTitle,
      fileName: fileName ?? this.fileName,
      path: path ?? this.path,
      sha1: sha1 ?? this.sha1,
      size: size ?? this.size,
      crc32: crc32 ?? this.crc32,
      addedAt: addedAt ?? this.addedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      playSeconds: playSeconds ?? this.playSeconds,
      favorite: favorite ?? this.favorite,
      customArtPath: customArtPath ?? this.customArtPath,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (system.present) {
      map['system'] = Variable<String>(system.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (searchTitle.present) {
      map['search_title'] = Variable<String>(searchTitle.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (sha1.present) {
      map['sha1'] = Variable<String>(sha1.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (crc32.present) {
      map['crc32'] = Variable<String>(crc32.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    if (lastPlayedAt.present) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt.value);
    }
    if (playSeconds.present) {
      map['play_seconds'] = Variable<int>(playSeconds.value);
    }
    if (favorite.present) {
      map['favorite'] = Variable<bool>(favorite.value);
    }
    if (customArtPath.present) {
      map['custom_art_path'] = Variable<String>(customArtPath.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GamesCompanion(')
          ..write('id: $id, ')
          ..write('system: $system, ')
          ..write('title: $title, ')
          ..write('searchTitle: $searchTitle, ')
          ..write('fileName: $fileName, ')
          ..write('path: $path, ')
          ..write('sha1: $sha1, ')
          ..write('size: $size, ')
          ..write('crc32: $crc32, ')
          ..write('addedAt: $addedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('playSeconds: $playSeconds, ')
          ..write('favorite: $favorite, ')
          ..write('customArtPath: $customArtPath')
          ..write(')'))
        .toString();
  }
}

class $CheatsTable extends Cheats with TableInfo<$CheatsTable, Cheat> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CheatsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _gameIdMeta = const VerificationMeta('gameId');
  @override
  late final GeneratedColumn<int> gameId = GeneratedColumn<int>(
    'game_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES games (id)',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    gameId,
    name,
    code,
    format,
    enabled,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cheats';
  @override
  VerificationContext validateIntegrity(
    Insertable<Cheat> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('game_id')) {
      context.handle(
        _gameIdMeta,
        gameId.isAcceptableOrUnknown(data['game_id']!, _gameIdMeta),
      );
    } else if (isInserting) {
      context.missing(_gameIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    } else if (isInserting) {
      context.missing(_formatMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Cheat map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Cheat(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      gameId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}game_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $CheatsTable createAlias(String alias) {
    return $CheatsTable(attachedDatabase, alias);
  }
}

class Cheat extends DataClass implements Insertable<Cheat> {
  final int id;
  final int gameId;
  final String name;

  /// Normalised codes, one per line.
  final String code;
  final String format;
  final bool enabled;
  final DateTime createdAt;
  const Cheat({
    required this.id,
    required this.gameId,
    required this.name,
    required this.code,
    required this.format,
    required this.enabled,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['game_id'] = Variable<int>(gameId);
    map['name'] = Variable<String>(name);
    map['code'] = Variable<String>(code);
    map['format'] = Variable<String>(format);
    map['enabled'] = Variable<bool>(enabled);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  CheatsCompanion toCompanion(bool nullToAbsent) {
    return CheatsCompanion(
      id: Value(id),
      gameId: Value(gameId),
      name: Value(name),
      code: Value(code),
      format: Value(format),
      enabled: Value(enabled),
      createdAt: Value(createdAt),
    );
  }

  factory Cheat.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Cheat(
      id: serializer.fromJson<int>(json['id']),
      gameId: serializer.fromJson<int>(json['gameId']),
      name: serializer.fromJson<String>(json['name']),
      code: serializer.fromJson<String>(json['code']),
      format: serializer.fromJson<String>(json['format']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'gameId': serializer.toJson<int>(gameId),
      'name': serializer.toJson<String>(name),
      'code': serializer.toJson<String>(code),
      'format': serializer.toJson<String>(format),
      'enabled': serializer.toJson<bool>(enabled),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  Cheat copyWith({
    int? id,
    int? gameId,
    String? name,
    String? code,
    String? format,
    bool? enabled,
    DateTime? createdAt,
  }) => Cheat(
    id: id ?? this.id,
    gameId: gameId ?? this.gameId,
    name: name ?? this.name,
    code: code ?? this.code,
    format: format ?? this.format,
    enabled: enabled ?? this.enabled,
    createdAt: createdAt ?? this.createdAt,
  );
  Cheat copyWithCompanion(CheatsCompanion data) {
    return Cheat(
      id: data.id.present ? data.id.value : this.id,
      gameId: data.gameId.present ? data.gameId.value : this.gameId,
      name: data.name.present ? data.name.value : this.name,
      code: data.code.present ? data.code.value : this.code,
      format: data.format.present ? data.format.value : this.format,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Cheat(')
          ..write('id: $id, ')
          ..write('gameId: $gameId, ')
          ..write('name: $name, ')
          ..write('code: $code, ')
          ..write('format: $format, ')
          ..write('enabled: $enabled, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, gameId, name, code, format, enabled, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Cheat &&
          other.id == this.id &&
          other.gameId == this.gameId &&
          other.name == this.name &&
          other.code == this.code &&
          other.format == this.format &&
          other.enabled == this.enabled &&
          other.createdAt == this.createdAt);
}

class CheatsCompanion extends UpdateCompanion<Cheat> {
  final Value<int> id;
  final Value<int> gameId;
  final Value<String> name;
  final Value<String> code;
  final Value<String> format;
  final Value<bool> enabled;
  final Value<DateTime> createdAt;
  const CheatsCompanion({
    this.id = const Value.absent(),
    this.gameId = const Value.absent(),
    this.name = const Value.absent(),
    this.code = const Value.absent(),
    this.format = const Value.absent(),
    this.enabled = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  CheatsCompanion.insert({
    this.id = const Value.absent(),
    required int gameId,
    required String name,
    required String code,
    required String format,
    this.enabled = const Value.absent(),
    required DateTime createdAt,
  }) : gameId = Value(gameId),
       name = Value(name),
       code = Value(code),
       format = Value(format),
       createdAt = Value(createdAt);
  static Insertable<Cheat> custom({
    Expression<int>? id,
    Expression<int>? gameId,
    Expression<String>? name,
    Expression<String>? code,
    Expression<String>? format,
    Expression<bool>? enabled,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (gameId != null) 'game_id': gameId,
      if (name != null) 'name': name,
      if (code != null) 'code': code,
      if (format != null) 'format': format,
      if (enabled != null) 'enabled': enabled,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  CheatsCompanion copyWith({
    Value<int>? id,
    Value<int>? gameId,
    Value<String>? name,
    Value<String>? code,
    Value<String>? format,
    Value<bool>? enabled,
    Value<DateTime>? createdAt,
  }) {
    return CheatsCompanion(
      id: id ?? this.id,
      gameId: gameId ?? this.gameId,
      name: name ?? this.name,
      code: code ?? this.code,
      format: format ?? this.format,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (gameId.present) {
      map['game_id'] = Variable<int>(gameId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CheatsCompanion(')
          ..write('id: $id, ')
          ..write('gameId: $gameId, ')
          ..write('name: $name, ')
          ..write('code: $code, ')
          ..write('format: $format, ')
          ..write('enabled: $enabled, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$LibraryDatabase extends GeneratedDatabase {
  _$LibraryDatabase(QueryExecutor e) : super(e);
  $LibraryDatabaseManager get managers => $LibraryDatabaseManager(this);
  late final $GamesTable games = $GamesTable(this);
  late final $CheatsTable cheats = $CheatsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [games, cheats];
}

typedef $$GamesTableCreateCompanionBuilder = GamesCompanion Function({
  Value<int> id,
  required String system,
  required String title,
  required String searchTitle,
  required String fileName,
  required String path,
  required String sha1,
  required int size,
  required String crc32,
  required DateTime addedAt,
  Value<DateTime?> lastPlayedAt,
  Value<int> playSeconds,
  Value<bool> favorite,
  Value<String?> customArtPath,
});
typedef $$GamesTableUpdateCompanionBuilder = GamesCompanion Function({
  Value<int> id,
  Value<String> system,
  Value<String> title,
  Value<String> searchTitle,
  Value<String> fileName,
  Value<String> path,
  Value<String> sha1,
  Value<int> size,
  Value<String> crc32,
  Value<DateTime> addedAt,
  Value<DateTime?> lastPlayedAt,
  Value<int> playSeconds,
  Value<bool> favorite,
  Value<String?> customArtPath,
});

final class $$GamesTableReferences
    extends BaseReferences<_$LibraryDatabase, $GamesTable, Game> {
  $$GamesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$CheatsTable, List<Cheat>> _cheatsRefsTable(
    _$LibraryDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.cheats,
    aliasName: 'games__id__cheats__game_id',
  );

  $$CheatsTableProcessedTableManager get cheatsRefs {
    final manager = $$CheatsTableTableManager(
      $_db,
      $_db.cheats,
    ).filter((f) => f.gameId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_cheatsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$GamesTableFilterComposer
    extends Composer<_$LibraryDatabase, $GamesTable> {
  $$GamesTableFilterComposer({
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

  ColumnFilters<String> get system => $composableBuilder(
    column: $table.system,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get searchTitle => $composableBuilder(
    column: $table.searchTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha1 => $composableBuilder(
    column: $table.sha1,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get crc32 => $composableBuilder(
    column: $table.crc32,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get playSeconds => $composableBuilder(
    column: $table.playSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get customArtPath => $composableBuilder(
    column: $table.customArtPath,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> cheatsRefs(
    Expression<bool> Function($$CheatsTableFilterComposer f) f,
  ) {
    final $$CheatsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.cheats,
      getReferencedColumn: (t) => t.gameId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CheatsTableFilterComposer(
            $db: $db,
            $table: $db.cheats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$GamesTableOrderingComposer
    extends Composer<_$LibraryDatabase, $GamesTable> {
  $$GamesTableOrderingComposer({
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

  ColumnOrderings<String> get system => $composableBuilder(
    column: $table.system,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get searchTitle => $composableBuilder(
    column: $table.searchTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha1 => $composableBuilder(
    column: $table.sha1,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get crc32 => $composableBuilder(
    column: $table.crc32,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get playSeconds => $composableBuilder(
    column: $table.playSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get customArtPath => $composableBuilder(
    column: $table.customArtPath,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GamesTableAnnotationComposer
    extends Composer<_$LibraryDatabase, $GamesTable> {
  $$GamesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get system =>
      $composableBuilder(column: $table.system, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get searchTitle => $composableBuilder(
    column: $table.searchTitle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get sha1 =>
      $composableBuilder(column: $table.sha1, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<String> get crc32 =>
      $composableBuilder(column: $table.crc32, builder: (column) => column);

  GeneratedColumn<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get playSeconds => $composableBuilder(
    column: $table.playSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get favorite =>
      $composableBuilder(column: $table.favorite, builder: (column) => column);

  GeneratedColumn<String> get customArtPath => $composableBuilder(
    column: $table.customArtPath,
    builder: (column) => column,
  );

  Expression<T> cheatsRefs<T extends Object>(
    Expression<T> Function($$CheatsTableAnnotationComposer a) f,
  ) {
    final $$CheatsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.cheats,
      getReferencedColumn: (t) => t.gameId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CheatsTableAnnotationComposer(
            $db: $db,
            $table: $db.cheats,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$GamesTableTableManager
    extends
        RootTableManager<
          _$LibraryDatabase,
          $GamesTable,
          Game,
          $$GamesTableFilterComposer,
          $$GamesTableOrderingComposer,
          $$GamesTableAnnotationComposer,
          $$GamesTableCreateCompanionBuilder,
          $$GamesTableUpdateCompanionBuilder,
          (Game, $$GamesTableReferences),
          Game,
          PrefetchHooks Function({bool cheatsRefs})
        > {
  $$GamesTableTableManager(_$LibraryDatabase db, $GamesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GamesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GamesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GamesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> system = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> searchTitle = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String> sha1 = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<String> crc32 = const Value.absent(),
                Value<DateTime> addedAt = const Value.absent(),
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                Value<int> playSeconds = const Value.absent(),
                Value<bool> favorite = const Value.absent(),
                Value<String?> customArtPath = const Value.absent(),
              }) => GamesCompanion(
                id: id,
                system: system,
                title: title,
                searchTitle: searchTitle,
                fileName: fileName,
                path: path,
                sha1: sha1,
                size: size,
                crc32: crc32,
                addedAt: addedAt,
                lastPlayedAt: lastPlayedAt,
                playSeconds: playSeconds,
                favorite: favorite,
                customArtPath: customArtPath,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String system,
                required String title,
                required String searchTitle,
                required String fileName,
                required String path,
                required String sha1,
                required int size,
                required String crc32,
                required DateTime addedAt,
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                Value<int> playSeconds = const Value.absent(),
                Value<bool> favorite = const Value.absent(),
                Value<String?> customArtPath = const Value.absent(),
              }) => GamesCompanion.insert(
                id: id,
                system: system,
                title: title,
                searchTitle: searchTitle,
                fileName: fileName,
                path: path,
                sha1: sha1,
                size: size,
                crc32: crc32,
                addedAt: addedAt,
                lastPlayedAt: lastPlayedAt,
                playSeconds: playSeconds,
                favorite: favorite,
                customArtPath: customArtPath,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$GamesTable, Game>(table),
                  $$GamesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({cheatsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (cheatsRefs) db.cheats],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (cheatsRefs)
                    await $_getPrefetchedData<Game, $GamesTable, Cheat>(
                      currentTable: table,
                      referencedTable: $$GamesTableReferences._cheatsRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$GamesTableReferences(db, table, p0).cheatsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.gameId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$GamesTableProcessedTableManager =
    ProcessedTableManager<
      _$LibraryDatabase,
      $GamesTable,
      Game,
      $$GamesTableFilterComposer,
      $$GamesTableOrderingComposer,
      $$GamesTableAnnotationComposer,
      $$GamesTableCreateCompanionBuilder,
      $$GamesTableUpdateCompanionBuilder,
      (Game, $$GamesTableReferences),
      Game,
      PrefetchHooks Function({bool cheatsRefs})
    >;
typedef $$CheatsTableCreateCompanionBuilder = CheatsCompanion Function({
  Value<int> id,
  required int gameId,
  required String name,
  required String code,
  required String format,
  Value<bool> enabled,
  required DateTime createdAt,
});
typedef $$CheatsTableUpdateCompanionBuilder = CheatsCompanion Function({
  Value<int> id,
  Value<int> gameId,
  Value<String> name,
  Value<String> code,
  Value<String> format,
  Value<bool> enabled,
  Value<DateTime> createdAt,
});

final class $$CheatsTableReferences
    extends BaseReferences<_$LibraryDatabase, $CheatsTable, Cheat> {
  $$CheatsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $GamesTable _gameIdTable(_$LibraryDatabase db) =>
      db.games.createAlias('cheats__game_id__games__id');

  $$GamesTableProcessedTableManager get gameId {
    final $_column = $_itemColumn<int>('game_id')!;

    final manager = $$GamesTableTableManager(
      $_db,
      $_db.games,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_gameIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CheatsTableFilterComposer
    extends Composer<_$LibraryDatabase, $CheatsTable> {
  $$CheatsTableFilterComposer({
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

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$GamesTableFilterComposer get gameId {
    final $$GamesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.gameId,
      referencedTable: $db.games,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GamesTableFilterComposer(
            $db: $db,
            $table: $db.games,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CheatsTableOrderingComposer
    extends Composer<_$LibraryDatabase, $CheatsTable> {
  $$CheatsTableOrderingComposer({
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

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$GamesTableOrderingComposer get gameId {
    final $$GamesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.gameId,
      referencedTable: $db.games,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GamesTableOrderingComposer(
            $db: $db,
            $table: $db.games,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CheatsTableAnnotationComposer
    extends Composer<_$LibraryDatabase, $CheatsTable> {
  $$CheatsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$GamesTableAnnotationComposer get gameId {
    final $$GamesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.gameId,
      referencedTable: $db.games,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GamesTableAnnotationComposer(
            $db: $db,
            $table: $db.games,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CheatsTableTableManager
    extends
        RootTableManager<
          _$LibraryDatabase,
          $CheatsTable,
          Cheat,
          $$CheatsTableFilterComposer,
          $$CheatsTableOrderingComposer,
          $$CheatsTableAnnotationComposer,
          $$CheatsTableCreateCompanionBuilder,
          $$CheatsTableUpdateCompanionBuilder,
          (Cheat, $$CheatsTableReferences),
          Cheat,
          PrefetchHooks Function({bool gameId})
        > {
  $$CheatsTableTableManager(_$LibraryDatabase db, $CheatsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CheatsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CheatsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CheatsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> gameId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> code = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => CheatsCompanion(
                id: id,
                gameId: gameId,
                name: name,
                code: code,
                format: format,
                enabled: enabled,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int gameId,
                required String name,
                required String code,
                required String format,
                Value<bool> enabled = const Value.absent(),
                required DateTime createdAt,
              }) => CheatsCompanion.insert(
                id: id,
                gameId: gameId,
                name: name,
                code: code,
                format: format,
                enabled: enabled,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$CheatsTable, Cheat>(table),
                  $$CheatsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({gameId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (gameId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.gameId,
                        referencedTable: $$CheatsTableReferences._gameIdTable(
                          db,
                        ),
                        referencedColumn: $$CheatsTableReferences
                            ._gameIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CheatsTableProcessedTableManager =
    ProcessedTableManager<
      _$LibraryDatabase,
      $CheatsTable,
      Cheat,
      $$CheatsTableFilterComposer,
      $$CheatsTableOrderingComposer,
      $$CheatsTableAnnotationComposer,
      $$CheatsTableCreateCompanionBuilder,
      $$CheatsTableUpdateCompanionBuilder,
      (Cheat, $$CheatsTableReferences),
      Cheat,
      PrefetchHooks Function({bool gameId})
    >;

class $LibraryDatabaseManager {
  final _$LibraryDatabase _db;
  $LibraryDatabaseManager(this._db);
  $$GamesTableTableManager get games =>
      $$GamesTableTableManager(_db, _db.games);
  $$CheatsTableTableManager get cheats =>
      $$CheatsTableTableManager(_db, _db.cheats);
}
