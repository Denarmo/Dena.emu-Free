import 'package:dena_emu/src/desktop/desktop_pads.dart';

/// Gamepads for tests: set [pads], then [press] / [release] actions.
class FakePads implements DesktopPads {
  FakePads({this.pads = 0, this.hostFamily = -1});

  int pads;
  int hostFamily;
  void Function(int action, bool down, int family)? _onAction;
  bool closed = false;

  @override
  int count() => pads;

  @override
  int family() => hostFamily;

  @override
  void listen(void Function(int action, bool down, int family) onAction) =>
      _onAction = onAction;

  @override
  void close() {
    closed = true;
    _onAction = null;
  }

  void press(int action, {int family = 1}) =>
      _onAction?.call(action, true, family);
  void release(int action, {int family = 1}) =>
      _onAction?.call(action, false, family);
}
