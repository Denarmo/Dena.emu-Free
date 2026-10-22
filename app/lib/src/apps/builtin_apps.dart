// SPDX-License-Identifier: GPL-3.0-or-later
// Built-in apps shown at the top of the Apps tab. Spec: docs/specs/apps-tab.md
import 'package:material_ui/material_ui.dart';

import '../media/music_screen.dart';
import '../media/video_screen.dart';
import '../shell/platform_features.dart';
import '../ui/dena_icons.dart';

/// An app that ships inside Dena.emu (e.g. the media player). Opened on the
/// route `apps/builtin/<id>`.
class BuiltInApp {
  const BuiltInApp({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
    this.routeName,
  });

  final String id;
  final String label;
  final IconData icon;

  /// Builds the app's full screen (it brings its own Scaffold / AppBar).
  final WidgetBuilder builder;

  /// Overrides `apps/builtin/<id>` for apps with their own named route.
  final String? routeName;

  String get route => routeName ?? builtInAppRoute(id);
}

/// `apps/builtin/<id>`.
String builtInAppRoute(String id) => 'apps/builtin/$id';

/// Every built-in app, in display order. To add one, append a single entry
/// here, e.g. `BuiltInApp(id: 'media', label: 'Media', icon: DenaIcons.playCircle, builder: (_) => const MediaPlayer()),`.
List<BuiltInApp> builtInApps() => [
  // The players use Android's MediaStore and Media3 (media-players.md).
  if (hasAndroidShell) ...[
    BuiltInApp(
      id: 'music',
      label: 'Music',
      icon: DenaIcons.musicNote,
      routeName: musicRoute,
      builder: (_) => const MusicScreen(),
    ),
    BuiltInApp(
      id: 'video',
      label: 'Video',
      icon: DenaIcons.film,
      routeName: videoRoute,
      builder: (_) => const VideoScreen(),
    ),
  ],
  ..._registered,
];

final _registered = <BuiltInApp>[];

/// Adds [app] at runtime (tests, optional modules). Same id replaces.
void registerBuiltInApp(BuiltInApp app) {
  _registered
    ..removeWhere((a) => a.id == app.id)
    ..add(app);
}

/// The built-in app with [id], or null.
BuiltInApp? builtInAppById(String id) {
  for (final a in builtInApps()) {
    if (a.id == id) return a;
  }
  return null;
}

/// Opens built-in app [id] on its `apps/builtin/<id>` route.
Future<void> openBuiltInApp(BuildContext context, String id) async {
  final app = builtInAppById(id);
  if (app != null) await pushBuiltInApp(context, app);
}

/// Pushes [app] on its `apps/builtin/<id>` route.
Future<void> pushBuiltInApp(BuildContext context, BuiltInApp app) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: app.route),
      builder: app.builder,
    ),
  );
}

/// Resolves `apps/builtin/<id>` names for `MaterialApp.onGenerateRoute`.
Route<void>? builtInAppRouteFor(RouteSettings settings) {
  final name = settings.name ?? '';
  const prefix = 'apps/builtin/';
  if (!name.startsWith(prefix)) return null;
  final app = builtInAppById(name.substring(prefix.length));
  if (app == null) return null;
  return MaterialPageRoute<void>(settings: settings, builder: app.builder);
}
