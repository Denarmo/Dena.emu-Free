// SPDX-License-Identifier: GPL-3.0-or-later
// The ROM manager: DAT checks, scraping and (on a PC) disc conversion, with
// its settings, handed to the UI through [RomManagerScope].
// Spec: docs/specs/rom-manager.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../library/database.dart';
import 'convert.dart';
import 'dat_store.dart';
import 'models.dart';
import 'openvgdb.dart';
import 'scraper.dart';
import 'screenscraper.dart';
import 'verify.dart';

/// The ROM manager's choices, in `romtools/settings.json`.
class RomSettings extends ChangeNotifier {
  RomSettings(this.file, {required this.defaultKinds});

  final File file;

  /// What SCRAPE fetches unless the user picked: every kind on a PC, no
  /// manuals or videos on a phone or handheld (rom-manager.md 4).
  final Set<ScrapeKind> defaultKinds;

  bool _keepOriginals = false;
  Set<ScrapeKind>? _kinds;

  /// Keep the original files after a verified conversion; off by default
  /// (rom-manager.md 3).
  bool get keepOriginals => _keepOriginals;
  set keepOriginals(bool v) {
    _keepOriginals = v;
    _changed();
  }

  Set<ScrapeKind> get kinds => _kinds ?? defaultKinds;

  /// Turns fetching [kind] on or off.
  void setKind(ScrapeKind kind, bool on) {
    final k = {...kinds};
    on ? k.add(kind) : k.remove(kind);
    _kinds = k;
    _changed();
  }

  Future<void> load() async {
    try {
      final v = jsonDecode(await file.readAsString());
      if (v case {'keepOriginals': final bool keep}) _keepOriginals = keep;
      if (v case {'kinds': final List<Object?> k}) {
        final names = ScrapeKind.values.asNameMap();
        _kinds = {for (final n in k.whereType<String>()) ?names[n]};
      }
    } on Object {
      // None yet, or damaged: defaults.
    }
  }

  void _changed() {
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'keepOriginals': _keepOriginals,
          if (_kinds case final k?) 'kinds': [for (final x in k) x.name],
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } on FileSystemException catch (e) {
      debugPrint('ROM manager settings not saved: $e');
    }
  }
}

/// Everything the ROM manager screens use.
class RomManager {
  RomManager({
    required this.dats,
    required this.results,
    required this.verifier,
    required this.scraper,
    required this.settings,
    this.account,
    this.openVgdb,
    this.conversions,
  });

  /// The app's ROM manager under [dataDir]. [desktop] adds conversion and
  /// the large scrape kinds.
  factory RomManager.open(
    String dataDir, {
    required LibraryDatabase db,
    required bool desktop,
  }) {
    final settings = RomSettings(
      File(p.join(dataDir, 'romtools', 'settings.json')),
      defaultKinds: desktop ? ScrapeKind.values.toSet() : ScrapeKind.small,
    );
    final dats = DatStore(dataDir);
    final results = VerifyResults(dataDir);
    final account = ScreenScraperAccount(
      dataDir,
      client: ScreenScraperClient.fromEnvironment(),
    );
    final openVgdb = OpenVgdb(dataDir);
    return RomManager(
      dats: dats,
      results: results,
      verifier: GameVerifier(dats: dats, results: results),
      scraper: Scraper(
        dataDir,
        openVgdb: openVgdb,
        screenScraper: account,
        kinds: () => settings.kinds,
      ),
      settings: settings,
      account: account,
      openVgdb: openVgdb,
      conversions: desktop
          ? ConversionQueue(
              tools: ToolLocator(dataDir: dataDir),
              onConverted: (game, out) => pointGameAt(db, game, out),
              keepOriginals: () => settings.keepOriginals,
            )
          : null,
    );
  }

  final DatStore dats;
  final VerifyResults results;
  final GameVerifier verifier;
  final Scraper scraper;
  final RomSettings settings;

  /// The user's ScreenScraper account; null where the app has no scraper.
  final ScreenScraperAccount? account;
  final OpenVgdb? openVgdb;

  /// Disc conversion, on Windows and SteamOS only.
  final ConversionQueue? conversions;

  /// Reads the stored DATs, results, account and settings.
  Future<void> load() async {
    await Future.wait([
      dats.load(),
      results.load(),
      settings.load(),
      ?account?.load(),
    ]);
  }

  /// Everything a screen redraws on.
  Listenable get changes => Listenable.merge([
    dats,
    results,
    verifier,
    scraper,
    settings,
    ?account,
    ?conversions,
  ]);

  /// [game]'s stored check, or null when it was never checked.
  VerifyResult? resultFor(Game game) => results[game.sha1];

  /// A deleted game's results and scraped files go too.
  Future<void> forget(Game game) async {
    await results.remove(game.sha1);
    await scraper.forget(game);
  }
}

/// Provides the [RomManager]; absent in tests that don't need it.
class RomManagerScope extends InheritedWidget {
  const RomManagerScope({
    super.key,
    required this.manager,
    required super.child,
  });

  final RomManager manager;

  static RomManager? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RomManagerScope>()?.manager;

  @override
  bool updateShouldNotify(RomManagerScope oldWidget) =>
      manager != oldWidget.manager;
}

/// The library filter by check result (rom-manager.md 5).
enum DatFilter {
  verified('Verified'),
  bad('Bad'),
  unknown('Unknown'),
  unchecked('Unchecked');

  const DatFilter(this.label);
  final String label;

  /// Whether a game with [result] passes.
  bool matches(VerifyResult? result) => switch (this) {
    DatFilter.verified => result?.status == VerifyStatus.verified,
    DatFilter.bad =>
      result?.status == VerifyStatus.badDump ||
          result?.status == VerifyStatus.modified,
    DatFilter.unknown => result?.status == VerifyStatus.unknown,
    DatFilter.unchecked =>
      result == null ||
          result.status == VerifyStatus.noDat ||
          result.status == VerifyStatus.unverifiable,
  };
}
