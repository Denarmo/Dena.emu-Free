import 'package:dena_emu/src/achievements/ra_native.dart';

/// Scripted native client: answers calls with the events the real one would
/// send after its server round trips.
class FakeRaNative implements RaNative {
  final calls = <String>[];
  final events = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];
  final responses = <(int, int, String)>[];

  /// Password that signs in; anything else is rejected.
  String password = 'secret';
  bool tokenValid = true;

  /// The game event sessionBegin answers with (null: no answer yet).
  Map<String, Object?>? game = {
    'type': 'game',
    'ok': true,
    'title': 'Test Game',
    'id': 77,
    'total': 2,
    'unlocked': 1,
    'points': 15,
    'points_unlocked': 5,
    'hardcore': true,
  };
  List<Object?>? list = [
    {
      'id': 1,
      'title': 'First',
      'description': 'Do one',
      'points': 5,
      'unlocked': 3,
    },
    {
      'id': 2,
      'title': 'Second',
      'description': 'Do two',
      'points': 10,
      'unlocked': 0,
      'progress': '3/10',
    },
  ];
  Map<String, Object?> gameInfo = {
    'type': 'game_info',
    'ok': true,
    'id': 77,
    'title': 'Test Game',
    'achievements': [
      {
        'id': 1,
        'title': 'First',
        'description': 'Do one',
        'points': 5,
        'unlocked': 2,
      },
      {
        'id': 2,
        'title': 'Second',
        'description': 'Do two',
        'points': 10,
        'unlocked': 0,
      },
    ],
  };
  bool loaded = false;

  static const account = {
    'user': 'tester',
    'display': 'Tester',
    'token': 'tok',
    'score': 120,
    'softcore_score': 4,
  };

  @override
  String userAgentClause() => 'rcheevos/12.5';

  @override
  void login(String user, String secret, {required bool token}) {
    calls.add('login $user ${token ? 'token' : 'password'}');
    final ok = token ? tokenValid : secret == password;
    events.add(
      ok
          ? {'type': 'login', 'ok': true, 'account': account}
          : {
              'type': 'login',
              'ok': false,
              'error': token
                  ? 'Invalid token'
                  : 'Invalid user/password combination.',
            },
    );
  }

  @override
  void logout() => calls.add('logout');

  @override
  void setHardcore(bool on) => calls.add('hardcore $on');

  @override
  Map<String, Object?>? takeRequest() =>
      requests.isEmpty ? null : requests.removeAt(0);

  @override
  void respond(int id, int status, List<int> body) =>
      responses.add((id, status, String.fromCharCodes(body)));

  @override
  Map<String, Object?>? takeEvent() =>
      events.isEmpty ? null : events.removeAt(0);

  @override
  void pump() {}

  @override
  void sessionBegin(String path, int consoleId) {
    calls.add('begin $path $consoleId');
    loaded = true;
    if (game != null) events.add(game!);
  }

  @override
  void sessionEnd() {
    calls.add('end');
    loaded = false;
  }

  @override
  List<Object?>? sessionList() => loaded ? list : null;

  @override
  void fetchGame(String path, int consoleId, int seq) {
    calls.add('fetch $path $consoleId');
    events.add({...gameInfo, 'seq': seq});
  }
}
