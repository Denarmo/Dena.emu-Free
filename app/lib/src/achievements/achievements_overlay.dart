// SPDX-License-Identifier: GPL-3.0-or-later
// The desktop's in-game RetroAchievements overlay: desktop-sized toasts in a
// chosen corner, a progress box, challenge badges and a hardcore sticker over
// the game, with an optional unlock chime, and its OVERLAY.CFG settings.
// Spec: docs/specs/achievements.md (Desktop overlay)
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../shell/host_library.dart';
import '../shell/platform_features.dart';
import '../ui/brutal/brutal.dart';
import 'achievements_ui.dart';
import 'retro_achievements.dart';

/// Where the toasts sit; the other pieces take the free corners.
enum RaToastCorner {
  topLeft('Top left', Alignment.topLeft),
  topRight('Top right', Alignment.topRight),
  bottomLeft('Bottom left', Alignment.bottomLeft),
  bottomRight('Bottom right', Alignment.bottomRight);

  const RaToastCorner(this.label, this.alignment);

  final String label;
  final Alignment alignment;

  /// The hardcore sticker: the same row, the other side.
  Alignment get stickerCorner => Alignment(-alignment.x, alignment.y);

  /// The progress box and challenge badges: the same side, the other row.
  Alignment get progressCorner => Alignment(alignment.x, -alignment.y);
}

/// How long each toast stays.
enum RaToastTime {
  short('3 s', Duration(seconds: 3)),
  normal('5 s', Duration(seconds: 5)),
  long('8 s', Duration(seconds: 8));

  const RaToastTime(this.label, this.duration);

  final String label;
  final Duration duration;
}

/// The overlay's choices, kept in `ra_overlay.json` in the data folder.
class RaOverlaySettings extends ChangeNotifier {
  RaOverlaySettings({
    this.file,
    this._corner = RaToastCorner.topRight,
    this._time = RaToastTime.normal,
    this._sound = false,
    this._progress = true,
    this._hardcoreSticker = true,
  });

  /// Reads [file]; a missing or damaged file gives the defaults.
  factory RaOverlaySettings.load(File file) {
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map) {
          T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
              values.firstWhere((v) => v.name == name, orElse: () => fallback);
          return RaOverlaySettings(
            file: file,
            corner: pick(
              RaToastCorner.values,
              j['corner'],
              RaToastCorner.topRight,
            ),
            time: pick(RaToastTime.values, j['time'], RaToastTime.normal),
            sound: j['sound'] as bool? ?? false,
            progress: j['progress'] as bool? ?? true,
            hardcoreSticker: j['hardcoreSticker'] as bool? ?? true,
          );
        }
      }
    } on Object {
      // Defaults; the next change rewrites the file.
    }
    return RaOverlaySettings(file: file);
  }

  final File? file;
  RaToastCorner _corner;
  RaToastTime _time;
  bool _sound, _progress, _hardcoreSticker;

  RaToastCorner get corner => _corner;
  set corner(RaToastCorner v) => _set(() => _corner = v, v != _corner);

  RaToastTime get time => _time;
  set time(RaToastTime v) => _set(() => _time = v, v != _time);

  /// The unlock chime over the game's audio (off by default).
  bool get sound => _sound;
  set sound(bool v) => _set(() => _sound = v, v != _sound);

  /// The progress box and challenge badges.
  bool get progress => _progress;
  set progress(bool v) => _set(() => _progress = v, v != _progress);

  /// The HARDCORE sticker for the whole of a hardcore session.
  bool get hardcoreSticker => _hardcoreSticker;
  set hardcoreSticker(bool v) =>
      _set(() => _hardcoreSticker = v, v != _hardcoreSticker);

  void _set(void Function() change, bool changed) {
    if (!changed) return;
    change();
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'corner': _corner.name,
          'time': _time.name,
          'sound': _sound,
          'progress': _progress,
          'hardcoreSticker': _hardcoreSticker,
        }),
      );
    } on Object catch (e) {
      debugPrint('Overlay settings not saved: $e');
    }
  }
}

/// Gives the game screen and Settings the overlay settings; absent off the
/// desktop, where the game keeps the plain top toasts.
class RaOverlayScope extends InheritedNotifier<RaOverlaySettings> {
  const RaOverlayScope({
    super.key,
    required RaOverlaySettings settings,
    required super.child,
  }) : super(notifier: settings);

  static RaOverlaySettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RaOverlayScope>()?.notifier;
}

/// `dena_desktop_chime` of the desktop host library (desktop.h); null off
/// the desktop or with an older library.
void Function()? openDesktopChime() {
  if (shellProfile != ShellProfile.desktop) return null;
  final lib = openHostLibrary();
  if (lib == null) return null;
  try {
    return lib.lookupFunction<Void Function(), void Function()>(
      'dena_desktop_chime',
    );
  } on ArgumentError {
    return null;
  }
}

/// [openDesktopChime], looked up once.
final void Function()? desktopChime = openDesktopChime();

/// Everything RetroAchievements draws over a desktop game.
class RaOverlay extends StatelessWidget {
  const RaOverlay({
    super.key,
    required this.ra,
    required this.settings,
    this.chime,
  });

  final RetroAchievements ra;
  final RaOverlaySettings settings;

  /// Plays the unlock chime; null leaves it silent.
  final void Function()? chime;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([ra, settings]),
    builder: (context, _) {
      final corner = settings.corner;
      final progress = settings.progress ? ra.progress : null;
      final challenges = settings.progress
          ? ra.challenges
          : const <RaAchievement>[];
      final hardcore =
          settings.hardcoreSticker && (ra.session?.hardcore ?? false);
      return IgnorePointer(
        child: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hardcore)
                Align(
                  alignment: corner.stickerCorner,
                  child: const Padding(
                    padding: EdgeInsets.all(BrutalTokens.s6),
                    child: Sticker('Hardcore', small: true),
                  ),
                ),
              if (progress != null || challenges.isNotEmpty)
                Align(
                  alignment: corner.progressCorner,
                  child: Padding(
                    padding: const EdgeInsets.all(BrutalTokens.s6),
                    child: _ProgressColumn(
                      progress: progress,
                      challenges: challenges,
                      alignment: corner.progressCorner,
                    ),
                  ),
                ),
              // Re-created when the corner or time changes, queue and all.
              RaToastLayer(
                key: ValueKey((corner, settings.time)),
                notices: ra.notices,
                alignment: corner.alignment,
                shown: settings.time.duration,
                large: true,
                onShow: (n) {
                  if (n is RaUnlockNotice || n is RaMasteredNotice) {
                    if (settings.sound) chime?.call();
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Challenge badges above the progress box, both on the overlay's free side.
class _ProgressColumn extends StatelessWidget {
  const _ProgressColumn({
    required this.progress,
    required this.challenges,
    required this.alignment,
  });

  final RaAchievement? progress;
  final List<RaAchievement> challenges;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    final p = progress;
    final right = alignment.x > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: right
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (challenges.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in challenges)
                Padding(
                  padding: const EdgeInsets.only(left: BrutalTokens.s2),
                  child: Container(
                    key: ValueKey('challenge-${c.id}'),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: t.focus,
                        width: BrutalTokens.border,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF000000),
                          offset: t.shadowOffset,
                        ),
                      ],
                    ),
                    child: RaSquareBadge(achievement: c),
                  ),
                ),
            ],
          ),
        if (challenges.isNotEmpty && p != null)
          const SizedBox(height: BrutalTokens.s3),
        if (p != null) _ProgressBox(achievement: p),
      ],
    );
  }
}

/// `TITLE` / `[######----] 6/20` in the toasts' black sticker.
class _ProgressBox extends StatelessWidget {
  const _ProgressBox({required this.achievement});

  final RaAchievement achievement;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    const white = Color(0xFFFFFFFF);
    final a = achievement;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        key: const ValueKey('ra-progress'),
        decoration: BoxDecoration(
          color: const Color(0xFF000000),
          border: Border.all(color: white, width: BrutalTokens.borderThin),
          boxShadow: [BoxShadow(color: t.focus, offset: t.shadowOffset)],
        ),
        padding: const EdgeInsets.all(BrutalTokens.s2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RaSquareBadge(achievement: a),
            const SizedBox(width: BrutalTokens.s3),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.label.copyWith(color: t.focus),
                  ),
                  const SizedBox(height: BrutalTokens.s1),
                  DefaultTextStyle.merge(
                    style: t.small.copyWith(color: white),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ProgressCell(
                          value: a.percent / 100,
                          showPercent: false,
                          width: 96,
                          color: white,
                        ),
                        const SizedBox(width: BrutalTokens.s2),
                        Text(a.progress),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The `OVERLAY.CFG` table of the RetroAchievements page (desktop only).
class RaOverlaySettingsTable extends StatelessWidget {
  const RaOverlaySettingsTable({super.key, required this.settings});

  final RaOverlaySettings settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => CfgTable(
      header: 'OVERLAY.CFG',
      rows: [
        CfgRow(
          label: 'Toasts',
          control: CfgSegment<RaToastCorner>(
            values: RaToastCorner.values,
            selected: settings.corner,
            labelOf: (c) => c.label,
            onChanged: (c) => settings.corner = c,
          ),
        ),
        CfgRow(
          label: 'Toast time',
          control: CfgSegment<RaToastTime>(
            values: RaToastTime.values,
            selected: settings.time,
            labelOf: (v) => v.label,
            onChanged: (v) => settings.time = v,
          ),
        ),
        CfgRow(
          label: 'Unlock sound',
          control: CfgToggle(
            value: settings.sound,
            onChanged: (v) => settings.sound = v,
            semanticLabel: 'Unlock sound',
          ),
        ),
        CfgRow(
          label: 'Progress',
          control: CfgToggle(
            value: settings.progress,
            onChanged: (v) => settings.progress = v,
            semanticLabel: 'Progress',
          ),
        ),
        CfgRow(
          label: 'Hardcore sticker',
          control: CfgToggle(
            value: settings.hardcoreSticker,
            onChanged: (v) => settings.hardcoreSticker = v,
            semanticLabel: 'Hardcore sticker',
          ),
        ),
      ],
    ),
  );
}
