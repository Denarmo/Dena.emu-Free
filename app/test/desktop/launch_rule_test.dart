// Spec: docs/specs/controller-mode.md (Launch rule)
import 'package:dena_emu/src/desktop/launch_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a gamepad at launch means fullscreen and controller mode on Auto', () {
    expect(decideLaunch(setting: FullscreenAtLaunch.auto, gamepads: 1), (
      fullscreen: true,
      controllerMode: true,
    ));
    expect(decideLaunch(setting: FullscreenAtLaunch.auto, gamepads: 0), (
      fullscreen: false,
      controllerMode: false,
    ));
  });

  test('Always and Never set only the window', () {
    expect(decideLaunch(setting: FullscreenAtLaunch.always, gamepads: 0), (
      fullscreen: true,
      controllerMode: false,
    ));
    expect(decideLaunch(setting: FullscreenAtLaunch.never, gamepads: 2), (
      fullscreen: false,
      controllerMode: true,
    ));
  });

  test('the Steam Deck counts as a gamepad', () {
    expect(
      decideLaunch(
        setting: FullscreenAtLaunch.auto,
        gamepads: 0,
        steamDeck: true,
      ),
      (fullscreen: true, controllerMode: true),
    );
  });

  test('waits for a slow pad, up to the timeout', () async {
    var polls = 0;
    final found = await waitForGamepads(
      () => ++polls >= 4 ? 1 : 0,
      every: const Duration(milliseconds: 1),
    );
    expect(found, 1);
    expect(polls, 4);

    final watch = Stopwatch()..start();
    final none = await waitForGamepads(
      () => 0,
      timeout: const Duration(milliseconds: 60),
      every: const Duration(milliseconds: 5),
    );
    expect(none, 0);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(60));
  });

  test('a pad already there returns at once', () async {
    var polls = 0;
    expect(await waitForGamepads(() => ++polls), 1);
    expect(polls, 1);
  });

  test('detects the Steam Deck', () {
    String Function(String) files(Map<String, String> f) =>
        (p) => f[p] ?? (throw StateError('no $p'));
    expect(detectSteamDeck(env: {'SteamDeck': '1'}, os: 'linux'), isTrue);
    expect(
      detectSteamDeck(
        env: {},
        os: 'linux',
        readFile: files({
          '/sys/class/dmi/id/board_vendor': 'Valve\n',
          '/sys/class/dmi/id/board_name': 'Galileo\n',
        }),
      ),
      isTrue,
    );
    expect(
      detectSteamDeck(
        env: {},
        os: 'linux',
        readFile: files({
          '/sys/class/dmi/id/board_vendor': 'ASUSTeK\n',
          '/sys/class/dmi/id/board_name': 'PRIME\n',
        }),
      ),
      isFalse,
    );
    expect(detectSteamDeck(env: {}, os: 'linux', readFile: files({})), isFalse);
    expect(detectSteamDeck(env: {'SteamDeck': '1'}, os: 'windows'), isFalse);
  });
}
