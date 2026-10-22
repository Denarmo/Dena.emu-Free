// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/media-players.md (Music), brutalist-ui.md (4.8)

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'media_backend.dart';
import 'media_kit.dart';
import '../ui/brutal/brutal.dart';
import '../ui/dena_icons.dart';

/// Route name of the music player.
const musicRoute = 'apps/music';

/// Device music: SONGS / ALBUMS / ARTISTS tabs over a track table, a queue
/// that plays in the background, and a now-playing panel.
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key, this.backend});

  final MediaBackend? backend;

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

enum _Load { loading, denied, ready }

class _MusicScreenState extends State<MusicScreen> {
  late final MediaBackend backend = widget.backend ?? MediaBackend.instance;
  late final MusicController music = MusicController.of(backend);
  late final ThumbnailCache thumbs = ThumbnailCache(backend);
  _Load load = _Load.loading;
  List<MediaEntry> tracks = const [];
  int category = 0;
  int group = 0;
  bool nowPlaying = false;

  static const categories = <BrutalTabItem>[
    BrutalTabItem(icon: DenaIcons.musicNote, label: 'Songs'),
    BrutalTabItem(icon: DenaIcons.disc, label: 'Albums'),
    BrutalTabItem(icon: DenaIcons.person, label: 'Artists'),
  ];

  @override
  void initState() {
    super.initState();
    music.attach();
    music.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    music.removeListener(_changed);
    music.detach();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => load = _Load.loading);
    final ok = await backend.requestAccess(video: false);
    if (!ok) {
      if (mounted) setState(() => load = _Load.denied);
      return;
    }
    final list = await backend.list(video: false);
    if (!mounted) return;
    setState(() {
      tracks = list;
      load = _Load.ready;
    });
  }

  /// Albums or artists with their tracks, by name.
  List<(String, List<MediaEntry>)> get groups {
    if (category == 0) return [('All songs', tracks)];
    final map = <String, List<MediaEntry>>{};
    for (final t in tracks) {
      final key = category == 1
          ? (t.album.isEmpty ? 'Unknown album' : t.album)
          : (t.artist.isEmpty ? 'Unknown artist' : t.artist);
      (map[key] ??= []).add(t);
    }
    final keys = map.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final k in keys) (k, map[k]!)];
  }

  void _category(int i) => setState(() {
    category = i;
    group = 0;
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width > size.height && size.width >= 560;
    final Widget body = switch (load) {
      _Load.loading => const MediaLoading('music'),
      _Load.denied => MediaMessage(
        headline: 'No access.',
        text: 'Dena.emu needs access to your music to play it.',
        action: 'Allow access',
        onAction: _load,
      ),
      _Load.ready when tracks.isEmpty => const MediaMessage(
        headline: 'No music.',
        text: 'No music found on this device.',
      ),
      _Load.ready =>
        wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 11, child: _library()),
                  const SizedBox(width: BrutalTokens.s3),
                  Expanded(
                    flex: 9,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: BrutalTokens.s3),
                      child: NowPlaying(
                        music: music,
                        thumbs: thumbs,
                        compact: true,
                      ),
                    ),
                  ),
                ],
              )
            : nowPlaying
            ? Padding(
                padding: const EdgeInsets.only(bottom: BrutalTokens.s3),
                child: NowPlaying(music: music, thumbs: thumbs),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _library()),
                  if (music.current != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: BrutalTokens.s3),
                      child: _MiniPlayer(
                        music: music,
                        thumbs: thumbs,
                        onOpen: () => setState(() => nowPlaying = true),
                      ),
                    ),
                ],
              ),
    };
    return CallbackShortcuts(
      bindings: {
        ...categoryKeys(categories.length, category, _category),
        const SingleActivator(LogicalKeyboardKey.gameButtonX): music.toggle,
        const SingleActivator(LogicalKeyboardKey.gameButtonY): () =>
            setState(() => nowPlaying = !nowPlaying),
      },
      child: PopScope(
        canPop: !nowPlaying || wide,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => nowPlaying = false);
        },
        child: MediaScaffold(
          title: 'Music',
          autofocusBack: load == _Load.ready && tracks.isEmpty,
          actions: [
            if (!wide && music.current != null)
              MediaKey(
                tooltip: nowPlaying ? 'Library' : 'Now playing',
                active: nowPlaying,
                onPressed: () => setState(() => nowPlaying = !nowPlaying),
                icon: nowPlaying ? DenaIcons.playlist : DenaIcons.equalizer,
              ),
          ],
          child: body,
        ),
      ),
    );
  }

  Widget _library() {
    final all = groups;
    final g = group.clamp(0, all.length - 1);
    final list = all[g].$2;
    final current = music.current?.uri;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BrutalTabBar(
          tabs: categories,
          selected: category,
          iconAbove: false,
          onSelected: _category,
        ),
        const SizedBox(height: BrutalTokens.s2),
        if (category > 0) ...[
          SizedBox(
            height: _GroupTile.height,
            child: FocusTraversalGroup(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: all.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: BrutalTokens.s1),
                itemBuilder: (_, i) => _GroupTile(
                  key: ValueKey('group-$category-$i'),
                  name: all[i].$1,
                  count: all[i].$2.length,
                  art: thumbs.of(all[i].$2.first.uri),
                  selected: i == g,
                  icon: category == 1 ? DenaIcons.disc : DenaIcons.person,
                  onTap: () => setState(() => group = i),
                ),
              ),
            ),
          ),
          const SizedBox(height: BrutalTokens.s2),
        ],
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: BrutalTokens.s3),
            child: _TrackTable(
              // A new table per list, so its first row takes focus when the
              // focused row goes away (L1 / R1, another group).
              key: ValueKey('tracks-$category-$g'),
              tracks: list,
              current: current,
              showAlbum: category != 1,
              thumbs: thumbs,
              onPlay: (i) => music.play(list, i),
            ),
          ),
        ),
      ],
    );
  }
}

/// The track list: ART, TITLE, ARTIST, ALBUM (when there is room), TIME.
/// The playing track carries a play mark before its title.
class _TrackTable extends StatelessWidget {
  const _TrackTable({
    super.key,
    required this.tracks,
    required this.current,
    required this.showAlbum,
    required this.thumbs,
    required this.onPlay,
  });

  final List<MediaEntry> tracks;
  final String? current;
  final bool showAlbum;
  final ThumbnailCache thumbs;
  final ValueChanged<int> onPlay;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final artist = w >= 360;
        final album = showAlbum && w >= 560;
        final cols = <(String, BrutalColumn)>[
          ('art', const BrutalColumn('Art', width: 48)),
          ('title', const BrutalColumn('Title', flex: 3)),
          if (artist) ('artist', const BrutalColumn('Artist', flex: 2)),
          if (album) ('album', const BrutalColumn('Album', flex: 2)),
          ('time', const BrutalColumn('Time', width: 64, numeric: true)),
        ];
        final art = (t.rowHeight - 12).clamp(16.0, 36.0);
        return BrutalTable(
          columns: [for (final c in cols) c.$2],
          rowCount: tracks.length,
          autofocusRow: 0,
          onRowPressed: onPlay,
          cellBuilder: (context, row, col, lit) {
            final tr = tracks[row];
            final muted = TextStyle(color: lit ? t.onFocus : t.mutedText);
            switch (cols[col].$1) {
              case 'art':
                return MediaThumb(
                  future: thumbs.of(tr.uri),
                  icon: DenaIcons.musicNote,
                  width: art,
                  height: art,
                );
              case 'title':
                final title = Text(
                  BrutalTokens.fileName(tr.title),
                  key: ValueKey('track-${tr.uri}'),
                );
                if (tr.uri != current) return title;
                return Row(
                  children: [
                    Icon(
                      DenaIcons.play,
                      size: BrutalTokens.iconSize,
                      color: lit ? t.onFocus : t.primary,
                      semanticLabel: 'Playing',
                    ),
                    const SizedBox(width: BrutalTokens.s1),
                    Flexible(child: title),
                  ],
                );
              case 'artist':
                return Text(tr.artist.toUpperCase(), style: muted);
              case 'album':
                return Text(tr.album.toUpperCase(), style: muted);
              default:
                return Text(formatDuration(tr.durationMs));
            }
          },
        );
      },
    );
  }
}

/// An album or artist in the strip above the tracks: art, name, count.
class _GroupTile extends StatelessWidget {
  const _GroupTile({
    super.key,
    required this.name,
    required this.count,
    required this.art,
    required this.selected,
    required this.icon,
    required this.onTap,
  });

  static const double height = 60;

  final String name;
  final int count;
  final Future<Uint8List?> art;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = BrutalTokens.of(context);
    return BrutalPressable(
      onPressed: onTap,
      selected: selected,
      semanticLabel: name,
      builder: (context, s) {
        final yellow = selected || s.highlighted;
        final fg = yellow ? t.onFocus : t.ink;
        return BrutalShadowBox(
          pressed: s.pressed || selected,
          offset: t.shadowOffset,
          color: t.shadow,
          child: Container(
            width: 168,
            padding: const EdgeInsets.all(BrutalTokens.s1),
            decoration: BoxDecoration(
              color: yellow ? t.focus : t.panel,
              border: Border.all(
                color: selected && s.focused ? t.primary : t.ink,
                width: BrutalTokens.border,
              ),
            ),
            child: Row(
              children: [
                MediaThumb(future: art, icon: icon, width: 40, height: 40),
                const SizedBox(width: BrutalTokens.s2),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.label.copyWith(color: fg),
                      ),
                      Text(
                        count == 1 ? '1 SONG' : '$count SONGS',
                        style: t.small.copyWith(
                          color: yellow ? t.onFocus : t.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The portrait strip under the table: progress, art, title and
/// play / next keys. Tapping it opens the now-playing panel.
class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({
    required this.music,
    required this.thumbs,
    required this.onOpen,
  });

  final MusicController music;
  final ThumbnailCache thumbs;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tk = BrutalTokens.of(context);
    final t = music.current!;
    final s = music.status;
    return BrutalPressable(
      onPressed: onOpen,
      semanticLabel: 'Now playing',
      builder: (context, ps) {
        final lit = ps.highlighted;
        final fg = lit ? tk.onFocus : tk.ink;
        return BrutalPanel(
          fill: lit ? tk.focus : null,
          padding: const EdgeInsets.all(BrutalTokens.s2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, box) => ProgressCell(
                  value: s.durationMs > 0 ? s.positionMs / s.durationMs : 0,
                  showPercent: false,
                  width: box.maxWidth,
                  height: 6,
                  color: fg,
                ),
              ),
              const SizedBox(height: BrutalTokens.s2),
              Row(
                children: [
                  MediaThumb(
                    future: thumbs.of(t.uri),
                    icon: DenaIcons.musicNote,
                    width: 40,
                    height: 40,
                  ),
                  const SizedBox(width: BrutalTokens.s2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          BrutalTokens.fileName(t.title),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tk.row.copyWith(color: fg),
                        ),
                        Text(
                          t.artist.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tk.small.copyWith(
                            color: lit ? tk.onFocus : tk.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: BrutalTokens.s2),
                  MediaKey(
                    icon: s.playing ? DenaIcons.pause : DenaIcons.play,
                    tooltip: s.playing ? 'Pause' : 'Play',
                    primary: true,
                    onPressed: music.toggle,
                  ),
                  const SizedBox(width: BrutalTokens.s1),
                  MediaKey(
                    icon: DenaIcons.skipNext,
                    tooltip: 'Next',
                    onPressed: music.next,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The now-playing panel: large framed art, title, seek bar and transport
/// keys (shuffle, previous, play / pause, next, repeat).
class NowPlaying extends StatelessWidget {
  const NowPlaying({
    super.key,
    required this.music,
    required this.thumbs,
    this.compact = false,
  });

  final MusicController music;
  final ThumbnailCache thumbs;

  /// Side panel next to the library (landscape).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tk = BrutalTokens.of(context);
    final t = music.current;
    final s = music.status;
    if (t == null) {
      return const Align(
        alignment: Alignment.topCenter,
        child: BrutalPanel(
          header: 'NOW_PLAYING',
          padding: EdgeInsets.all(BrutalTokens.s3),
          child: LogLine('pick a song to start playing'),
        ),
      );
    }
    const repeatNames = ['Repeat off', 'Repeat one', 'Repeat all'];
    List<Widget> keysOf(double side) => [
      MediaKey(
        size: side,
        icon: DenaIcons.shuffle,
        tooltip: s.shuffle ? 'Shuffle on' : 'Shuffle off',
        active: s.shuffle,
        onPressed: music.toggleShuffle,
      ),
      MediaKey(
        size: side,
        icon: DenaIcons.skipPrevious,
        tooltip: 'Previous',
        onPressed: music.previous,
      ),
      MediaKey(
        size: side,
        icon: s.playing ? DenaIcons.pause : DenaIcons.play,
        tooltip: s.playing ? 'Pause' : 'Play',
        primary: true,
        autofocus: !compact,
        onPressed: music.toggle,
      ),
      MediaKey(
        size: side,
        icon: DenaIcons.skipNext,
        tooltip: 'Next',
        onPressed: music.next,
      ),
      MediaKey(
        size: side,
        icon: s.repeat == 1 ? DenaIcons.repeatOne : DenaIcons.repeat,
        tooltip: repeatNames[s.repeat.clamp(0, 2)],
        active: s.repeat != 0,
        onPressed: music.cycleRepeat,
      ),
    ];
    final modes =
        'SHUFFLE [${s.shuffle ? 'ON' : 'OFF'}]  '
        'REPEAT [${const ['OFF', 'ONE', 'ALL'][s.repeat.clamp(0, 2)]}]';
    return LayoutBuilder(
      builder: (context, box) {
        // Panel border, shadow and padding around the content.
        final chromeW =
            2 * BrutalTokens.border + tk.shadowOffset.dx + 2 * BrutalTokens.s3;
        final inner = box.maxWidth - chromeW;
        // Keys get smaller in a narrow side panel so five fit on one row.
        final keySide = ((inner - 4 * BrutalTokens.s1) / 5 - tk.shadowOffset.dx)
            .clamp(28.0, tk.buttonHeight);
        // Header strip, title, meta, seek bar, keys, mode line and gaps.
        final chromeH =
            26 +
            2 * BrutalTokens.border +
            tk.shadowOffset.dy +
            2 * BrutalTokens.s3 +
            24 +
            16 +
            36 +
            keySide +
            tk.shadowOffset.dy +
            14 +
            BrutalTokens.s3 +
            3 * BrutalTokens.s2 +
            tk.shadowOffsetLarge.dy +
            8;
        final art = (box.maxHeight - chromeH).clamp(
          40.0,
          inner.clamp(40.0, 360.0),
        );
        return SingleChildScrollView(
          child: BrutalPanel(
            header: 'NOW_PLAYING',
            headerTrailing: Text(
              s.playing ? '[PLAY]' : '[PAUSE]',
              style: tk.label.copyWith(color: tk.onHeaderBar),
            ),
            padding: const EdgeInsets.all(BrutalTokens.s3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MediaThumb(
                  future: thumbs.of(t.uri, size: 512),
                  icon: DenaIcons.musicNote,
                  width: art,
                  height: art,
                  shadow: true,
                ),
                const SizedBox(height: BrutalTokens.s3),
                Text(
                  BrutalTokens.fileName(t.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tk.title,
                ),
                Text(
                  [
                    t.artist,
                    t.album,
                  ].where((x) => x.isNotEmpty).join(' // ').toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tk.small.copyWith(color: tk.mutedText),
                ),
                const SizedBox(height: BrutalTokens.s2),
                MediaSeekBar(
                  positionMs: s.positionMs,
                  durationMs: s.durationMs,
                  onSeek: music.seek,
                  format: formatDuration,
                ),
                const SizedBox(height: BrutalTokens.s2),
                FocusTraversalGroup(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final (i, k) in keysOf(
                        keySide.roundToDouble(),
                      ).indexed) ...[
                        if (i > 0) const SizedBox(width: BrutalTokens.s1),
                        k,
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: BrutalTokens.s2),
                Text(modes, style: tk.small.copyWith(color: tk.mutedText)),
              ],
            ),
          ),
        );
      },
    );
  }
}
