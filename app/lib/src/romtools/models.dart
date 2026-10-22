// SPDX-License-Identifier: GPL-3.0-or-later
// Shared types of the ROM manager: verification results and scraped data.
// Spec: docs/specs/rom-manager.md
library;

/// The outcome of checking a game against its system's DAT (rom-manager.md
/// 2).
enum VerifyStatus {
  verified('VERIFIED'),
  badDump('BAD DUMP'),
  modified('MODIFIED'),
  unknown('UNKNOWN'),
  unverifiable('COMPRESSED'),
  noDat('NO DAT');

  const VerifyStatus(this.label);

  /// Shown in INSPECT and on the ROM page.
  final String label;
}

/// One game's check, stored in `romtools/verify.json` by SHA-1.
class VerifyResult {
  const VerifyResult({
    required this.status,
    required this.checkedAt,
    this.name,
    this.source,
  });

  final VerifyStatus status;

  /// The DAT game the file matched (or, for [VerifyStatus.modified], the one
  /// its name names).
  final String? name;

  /// Where the DAT came from (`DatInfo.source`).
  final String? source;
  final DateTime checkedAt;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'name': ?name,
    'source': ?source,
    'checkedAt': checkedAt.toIso8601String(),
  };

  static VerifyResult? fromJson(Object? json) {
    if (json case {'status': final String s, 'checkedAt': final String at}) {
      final status = VerifyStatus.values.asNameMap()[s];
      final when = DateTime.tryParse(at);
      if (status == null || when == null) return null;
      return VerifyResult(
        status: status,
        checkedAt: when,
        name: (json as Map)['name'] as String?,
        source: json['source'] as String?,
      );
    }
    return null;
  }
}

/// What a scraper can fetch for a game (rom-manager.md 4).
enum ScrapeKind {
  cover,
  box3d,
  back,
  screenshot,
  manual,
  video;

  /// The file extension it is stored with.
  String get extension => switch (this) {
    ScrapeKind.manual => '.pdf',
    ScrapeKind.video => '.mp4',
    _ => '.png',
  };

  /// Short label for the ROM page.
  String get label => switch (this) {
    ScrapeKind.cover => 'COVER',
    ScrapeKind.box3d => 'BOX',
    ScrapeKind.back => 'BACK',
    ScrapeKind.screenshot => 'SNAP',
    ScrapeKind.manual => 'MANUAL',
    ScrapeKind.video => 'VIDEO',
  };

  /// The kinds phones and handhelds fetch: no manuals or videos.
  static const small = {cover, box3d, back, screenshot};
}

/// Facts and media URLs one source knows about a game.
class ScrapedGame {
  const ScrapedGame({
    required this.source,
    this.title,
    this.description,
    this.developer,
    this.publisher,
    this.genre,
    this.year,
    this.players,
    this.media = const {},
  });

  /// `openvgdb` or `screenscraper`.
  final String source;
  final String? title, description, developer, publisher, genre, players;
  final int? year;
  final Map<ScrapeKind, Uri> media;

  /// This game's facts, with [other] filling the gaps.
  ScrapedGame merge(ScrapedGame other) => ScrapedGame(
    source: source,
    title: title ?? other.title,
    description: description ?? other.description,
    developer: developer ?? other.developer,
    publisher: publisher ?? other.publisher,
    genre: genre ?? other.genre,
    year: year ?? other.year,
    players: players ?? other.players,
    media: {...other.media, ...media},
  );

  Map<String, Object?> toJson() => {
    'source': source,
    'title': ?title,
    'description': ?description,
    'developer': ?developer,
    'publisher': ?publisher,
    'genre': ?genre,
    'year': ?year,
    'players': ?players,
  };

  static ScrapedGame fromJson(Map<String, Object?> json) => ScrapedGame(
    source: json['source'] as String? ?? '',
    title: json['title'] as String?,
    description: json['description'] as String?,
    developer: json['developer'] as String?,
    publisher: json['publisher'] as String?,
    genre: json['genre'] as String?,
    year: json['year'] as int?,
    players: json['players'] as String?,
  );
}
