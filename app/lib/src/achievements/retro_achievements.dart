// SPDX-License-Identifier: GPL-3.0-or-later
// RetroAchievements account, settings and sessions. The native client does
// the protocol; this class sends its HTTP requests and turns its events into
// app state. Spec: docs/specs/achievements.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'ra_native.dart';

/// RetroAchievements console ids (rcheevos rc_consoles.h) of the systems that
/// have achievements. PICO-8 has none.
const raConsoleIds = {
  'nes': 7,
  'snes': 3,
  'gb': 4,
  'gbc': 6,
  'gba': 5,
  'n64': 2,
  'nds': 18,
  'psx': 12,
  'psp': 41,
  'saturn': 39,
  'dreamcast': 40,
  'gamecube': 16,
  'wii': 19,
  'ps2': 21,
};

/// Sends one request: returns the HTTP status (negative when the network
/// failed) and the body.
typedef RaHttp = Future<(int, List<int>)> Function(
  String url,
  String? post,
  String? contentType,
  String userAgent,
);

Future<(int, List<int>)> ioRaHttp(
  String url,
  String? post,
  String? contentType,
  String userAgent,
) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = userAgent;
  try {
    final req = post == null
        ? await client.getUrl(Uri.parse(url))
        : await client.postUrl(Uri.parse(url));
    if (post != null) {
      req.headers.contentType = ContentType.parse(
        contentType ?? 'application/x-www-form-urlencoded',
      );
      req.write(post);
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res.statusCode, body);
  } on Object {
    return (-1, const <int>[]);
  } finally {
    client.close();
  }
}

class RaAccount {
  const RaAccount({
    required this.user,
    required this.token,
    this.display,
    this.score = 0,
    this.softcoreScore = 0,
    this.avatar,
  });

  final String user;
  final String token;
  final String? display;
  final int score;
  final int softcoreScore;
  final String? avatar;

  String get name => display?.isNotEmpty == true ? display! : user;

  static RaAccount? fromJson(Object? j) {
    if (j is! Map) return null;
    final user = j['user'], token = j['token'];
    if (user is! String || token is! String || token.isEmpty) return null;
    return RaAccount(
      user: user,
      token: token,
      display: j['display'] as String?,
      score: (j['score'] as num?)?.toInt() ?? 0,
      softcoreScore: (j['softcore_score'] as num?)?.toInt() ?? 0,
      avatar: j['avatar'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'user': user,
    'token': token,
    'display': display,
    'score': score,
    'softcore_score': softcoreScore,
    'avatar': avatar,
  };
}

/// Unlock state of one achievement for the signed-in user.
enum RaUnlock { locked, softcore, hardcore }

class RaAchievement {
  const RaAchievement({
    required this.id,
    required this.title,
    required this.description,
    required this.points,
    this.unlock = RaUnlock.locked,
    this.badge,
    this.badgeLocked,
    this.progress = '',
    this.percent = 0,
  });

  final int id;
  final String title;
  final String description;
  final int points;
  final RaUnlock unlock;
  final String? badge;
  final String? badgeLocked;

  /// Measured progress such as "3/10" (session lists only).
  final String progress;

  /// Measured progress from 0 to 100 (progress and challenge events).
  final double percent;

  bool get unlocked => unlock != RaUnlock.locked;

  /// [j] from a session list (unlocked: 0 none, 1 softcore, 2 hardcore,
  /// 3 both) or a game_info event (0, 1 softcore, 2 hardcore).
  static RaAchievement fromJson(Map<String, Object?> j) {
    final u = (j['unlocked'] as num?)?.toInt() ?? 0;
    return RaAchievement(
      id: (j['id'] as num?)?.toInt() ?? 0,
      title: j['title'] as String? ?? '',
      description: j['description'] as String? ?? '',
      points: (j['points'] as num?)?.toInt() ?? 0,
      unlock: u & 2 != 0
          ? RaUnlock.hardcore
          : u & 1 != 0
          ? RaUnlock.softcore
          : RaUnlock.locked,
      badge: j['badge'] as String?,
      badgeLocked: j['badge_locked'] as String?,
      progress: j['progress'] as String? ?? '',
      percent: (j['percent'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// A game's achievements for the game page.
class RaGameInfo {
  const RaGameInfo({
    required this.id,
    required this.title,
    required this.achievements,
    this.image,
  });

  final int id;
  final String title;
  final String? image;
  final List<RaAchievement> achievements;

  int get unlocked => achievements.where((a) => a.unlocked).length;
  int get points => achievements.fold(0, (s, a) => s + a.points);
  int get pointsUnlocked =>
      achievements.where((a) => a.unlocked).fold(0, (s, a) => s + a.points);
}

/// Why a game page has no list.
class RaFetchError implements Exception {
  const RaFetchError(this.message, {this.unknown = false});
  final String message;

  /// RetroAchievements does not know this ROM.
  final bool unknown;
  @override
  String toString() => message;
}

/// The running game as RetroAchievements identified it.
class RaSession {
  const RaSession({
    required this.title,
    required this.total,
    required this.unlocked,
    required this.hardcore,
    this.image,
  });

  final String title;
  final int total;
  final int unlocked;
  final bool hardcore;
  final String? image;

  RaSession copyWith({int? unlocked}) => RaSession(
    title: title,
    total: total,
    unlocked: unlocked ?? this.unlocked,
    hardcore: hardcore,
    image: image,
  );
}

/// What a session shows as a toast.
sealed class RaNotice {
  const RaNotice();
}

class RaGameNotice extends RaNotice {
  const RaGameNotice(this.session);
  final RaSession session;
}

class RaUnknownGameNotice extends RaNotice {
  const RaUnknownGameNotice();
}

class RaUnlockNotice extends RaNotice {
  const RaUnlockNotice(this.achievement, {required this.hardcore});
  final RaAchievement achievement;
  final bool hardcore;
}

class RaMasteredNotice extends RaNotice {
  const RaMasteredNotice(this.title);
  final String title;
}

class RaOfflineNotice extends RaNotice {
  const RaOfflineNotice({required this.offline});
  final bool offline;
}

class RetroAchievements extends ChangeNotifier {
  RetroAchievements({
    required this.native,
    required String dataDir,
    this.http = ioRaHttp,
    this.appVersion = const String.fromEnvironment('FLUTTER_BUILD_NAME'),
  }) : _file = File(p.join(dataDir, 'retroachievements.json')) {
    _load();
  }

  final RaNative native;
  final RaHttp http;

  /// The app version for the User-Agent (`Dena.emu/<version>`).
  final String appVersion;
  final File _file;

  RaAccount? _account;
  bool _hardcore = true;

  /// The signed-in account (kept across launches as a token, never the
  /// password).
  RaAccount? get account => _account;

  /// Hardcore mode for the next game (on by default, as on the site).
  bool get hardcore => _hardcore;

  /// The native client has the account signed in (false until the token is
  /// checked, and while offline).
  bool get online => _nativeUser != null;
  String? _nativeUser;

  RaSession? _session;
  bool _inSession = false;
  RaSession? get session => _session;

  RaAchievement? _progress;
  final _challenges = <RaAchievement>[];

  /// The achievement whose measured progress just moved, while rcheevos
  /// shows it (about 2 s per change); the desktop overlay's progress box.
  RaAchievement? get progress => _progress;

  /// Primed achievements: their challenge is on now (desktop overlay).
  List<RaAchievement> get challenges => List.unmodifiable(_challenges);

  final _notices = StreamController<RaNotice>.broadcast();

  /// Toasts for the running session.
  Stream<RaNotice> get notices => _notices.stream;

  Completer<String?>? _login;
  final _fetches = <int, Completer<RaGameInfo>>{};
  int _seq = 0;
  int _inflight = 0;
  Timer? _timer;

  // ---- Settings file ----

  void _load() {
    try {
      if (!_file.existsSync()) return;
      final j = jsonDecode(_file.readAsStringSync());
      if (j is! Map) return;
      _account = RaAccount.fromJson(j['account']);
      _hardcore = j['hardcore'] as bool? ?? true;
    } on Object {
      // A damaged file counts as signed out; the next save rewrites it.
    }
    native.setHardcore(_hardcore);
  }

  void _save() {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        jsonEncode({'account': _account?.toJson(), 'hardcore': _hardcore}),
      );
    } on Object {
      // Settings stay in memory for this run.
    }
  }

  // ---- Account ----

  /// Signs in with a password. Returns an error message, or null.
  Future<String?> signIn(String user, String password) async {
    final done = _login = Completer<String?>();
    native.login(user.trim(), password, token: false);
    _wake();
    return done.future;
  }

  /// Signs in the stored account with its token (once per launch).
  Future<void> _ensureSignedIn() async {
    final a = _account;
    if (a == null || online || _login != null) return;
    _login = Completer<String?>();
    native.login(a.user, a.token, token: true);
    _wake();
    await _login?.future;
  }

  void signOut() {
    native.logout();
    _account = null;
    _nativeUser = null;
    _save();
    notifyListeners();
  }

  set hardcore(bool on) {
    if (on == _hardcore) return;
    _hardcore = on;
    native.setHardcore(on);
    _save();
    notifyListeners();
  }

  /// [system] has achievements and an account is set up.
  bool supports(String system) =>
      _account != null && raConsoleIds.containsKey(system);

  /// A session of [system] would run in hardcore mode (no save-state loads,
  /// rewind or cheats; the auto-save state is not resumed).
  bool hardcoreFor(String system) => _hardcore && supports(system);

  // ---- Sessions ----

  /// Starts identifying the game at [path] after its core started.
  Future<void> beginSession(String path, String system) async {
    final console = raConsoleIds[system];
    if (console == null || _account == null) return;
    _inSession = true;
    _session = null;
    _progress = null;
    _challenges.clear();
    // rc_client waits for the login before it identifies the game.
    unawaited(_ensureSignedIn());
    native.sessionBegin(path, console);
    _wake();
  }

  /// Before the core stops.
  void endSession() {
    if (!_inSession) return;
    _inSession = false;
    _session = null;
    _progress = null;
    _challenges.clear();
    native.sessionEnd();
    notifyListeners();
  }

  /// The running game's achievements, unlocked first.
  List<RaAchievement> sessionAchievements() {
    final list = native.sessionList() ?? const [];
    return [
      for (final a in list)
        if (a is Map<String, Object?>) RaAchievement.fromJson(a),
    ];
  }

  // ---- Game page ----

  /// The achievements of [path] and the user's unlocks.
  Future<RaGameInfo> fetchGame(String path, String system) async {
    final console = raConsoleIds[system];
    if (console == null) {
      throw const RaFetchError('This system has no achievements');
    }
    if (_account == null) {
      throw const RaFetchError('Sign in to RetroAchievements first');
    }
    await _ensureSignedIn();
    if (!online) {
      throw const RaFetchError(
        "Can't reach RetroAchievements. Check the connection and try again.",
      );
    }
    final seq = ++_seq;
    final done = _fetches[seq] = Completer<RaGameInfo>();
    native.fetchGame(path, console, seq);
    _wake();
    return done.future;
  }

  // ---- Pump ----

  bool get _busy =>
      _inSession || _login != null || _fetches.isNotEmpty || _inflight > 0;

  void _wake() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 100), (_) => tick());
    tick();
  }

  /// Sends queued requests and handles events; runs on a timer while
  /// anything is pending. Public for tests.
  @visibleForTesting
  void tick() {
    native.pump();
    while (true) {
      final req = native.takeRequest();
      if (req == null) break;
      _send(req);
    }
    while (true) {
      final e = native.takeEvent();
      if (e == null) break;
      _handle(e);
    }
    if (!_busy) {
      _timer?.cancel();
      _timer = null;
    }
  }

  String get _userAgent =>
      'Dena.emu${appVersion.isEmpty ? '' : '/$appVersion'} '
      '(${Platform.operatingSystem}) '
      '${native.userAgentClause()}';

  Future<void> _send(Map<String, Object?> req) async {
    _inflight++;
    final (status, body) = await http(
      req['url'] as String? ?? '',
      req['post'] as String?,
      req['type'] as String?,
      _userAgent,
    );
    _inflight--;
    native.respond((req['id'] as num).toInt(), status, body);
    tick();
  }

  void _handle(Map<String, Object?> e) {
    switch (e['type']) {
      case 'login':
        final done = _login;
        _login = null;
        if (e['ok'] == true) {
          final a = RaAccount.fromJson(e['account']);
          if (a != null) {
            _account = a;
            _nativeUser = a.user;
            _save();
          }
          done?.complete(null);
        } else {
          final err = e['error'] as String? ?? 'Sign-in failed';
          // A rejected token signs out; a network failure keeps the account.
          if (_account != null &&
              _nativeUser == null &&
              err.toLowerCase().contains('invalid')) {
            _account = null;
            _save();
          }
          done?.complete(err);
        }
        notifyListeners();
      case 'game':
        if (!_inSession) return;
        if (e['ok'] == true) {
          _session = RaSession(
            title: e['title'] as String? ?? '',
            total: (e['total'] as num?)?.toInt() ?? 0,
            unlocked: (e['unlocked'] as num?)?.toInt() ?? 0,
            hardcore: e['hardcore'] == true,
            image: e['image'] as String?,
          );
          _notices.add(RaGameNotice(_session!));
        } else if (e['unknown'] == true) {
          _notices.add(const RaUnknownGameNotice());
        }
        notifyListeners();
      case 'unlock':
        final a = e['achievement'];
        if (a is! Map<String, Object?>) return;
        final s = _session;
        if (s != null) _session = s.copyWith(unlocked: s.unlocked + 1);
        final id = (a['id'] as num?)?.toInt();
        _challenges.removeWhere((c) => c.id == id);
        if (_progress?.id == id) _progress = null;
        _notices.add(
          RaUnlockNotice(
            RaAchievement.fromJson(a),
            hardcore: e['hardcore'] == true,
          ),
        );
        notifyListeners();
      case 'progress' || 'challenge':
        final a = e['achievement'];
        if (!_inSession || a is! Map<String, Object?>) return;
        final achievement = RaAchievement.fromJson(a);
        if (e['type'] == 'progress') {
          _progress = achievement;
        } else {
          _challenges
            ..removeWhere((c) => c.id == achievement.id)
            ..add(achievement);
        }
        notifyListeners();
      case 'progress_hide':
        _progress = null;
        notifyListeners();
      case 'challenge_hide':
        final id = (e['id'] as num?)?.toInt();
        _challenges.removeWhere((c) => c.id == id);
        notifyListeners();
      case 'mastered':
        _notices.add(RaMasteredNotice(e['title'] as String? ?? ''));
      case 'offline' || 'online':
        _notices.add(RaOfflineNotice(offline: e['type'] == 'offline'));
      case 'game_info':
        final done = _fetches.remove((e['seq'] as num?)?.toInt());
        if (done == null) return;
        if (e['ok'] != true) {
          final err = e['error'] as String? ?? 'unknown';
          done.completeError(
            err == 'unknown'
                ? const RaFetchError(
                    "RetroAchievements doesn't recognise this game file",
                    unknown: true,
                  )
                : RaFetchError(err),
          );
          return;
        }
        done.complete(
          RaGameInfo(
            id: (e['id'] as num?)?.toInt() ?? 0,
            title: e['title'] as String? ?? '',
            image: e['image'] as String?,
            achievements: [
              for (final a in e['achievements'] as List? ?? const [])
                if (a is Map<String, Object?>) RaAchievement.fromJson(a),
            ],
          ),
        );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _notices.close();
    super.dispose();
  }
}
