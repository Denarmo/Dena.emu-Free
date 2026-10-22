// SPDX-License-Identifier: GPL-3.0-or-later
// Dart side of the Android shell. Specs: docs/specs/latency-spike.md,
// docs/specs/game-session.md
library;

export 'src/emulator_view.dart';
export 'src/game_api.g.dart'
    show GameEventsApi, GameHostApi, StartOutcome, StartResult;
export 'src/library_api.g.dart' show LibraryHostApi;
export 'src/media_api.g.dart'
    show MediaEntry, MediaHostApi, MusicStatus, VideoStatus;
export 'src/spike_api.g.dart' show SpikeHostApi;
