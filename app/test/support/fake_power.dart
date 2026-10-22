import 'dart:async';

import 'package:dena_emu/src/shell/power_link.dart';

/// Stands in for the daemon socket: [incoming] is what the daemon says.
class FakePowerChannel implements PowerChannel {
  final incoming = StreamController<String>();
  final sent = <String>[];

  @override
  Stream<String> get lines => incoming.stream;

  @override
  void send(String line) => sent.add(line);
}
