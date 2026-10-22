// SPDX-License-Identifier: GPL-3.0-or-later
// Known romhacks whose names don't say which game they are built on.
// Spec: docs/specs/box-art.md ("Romhacks")
import 'box_art.dart';

/// A romhack the box-art lookup knows by name.
class Romhack {
  const Romhack(this.system, this.names, this.base, [this.art = const []]);

  /// The system the hack runs on (its base game's system).
  final String system;

  /// [hackKey]s of the hack's name without spaces and without a leading
  /// `pokemon`: `polishedcrystal`, `radicalred`.
  final List<String> names;

  /// The base game's title as the index names it; its cover is the fallback.
  final String base;

  /// The hack's own covers on the thumbnail server, best first.
  final List<String> art;
}

const romhacks = [
  // Game Boy Advance, on Emerald.
  Romhack('gba', ['seaglass', 'emeraldseaglass'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['inclementemerald'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['emeraldrogue'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['emeraldimperium'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['emeraldkaizo'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['emeraldhorizons'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['emeraldcrest'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['emeraldex'], 'Pokemon - Emerald Version'),
  Romhack('gba', ['flora', 'florasky'], 'Pokemon - Emerald Version'),
  Romhack(
    'gba',
    ['thetaemerald', 'thetaemeraldex'],
    'Pokemon - Emerald Version',
    ['Pokemon - Theta Emerald EX Version (Hack)'],
  ),
  Romhack(
    'gba',
    ['glazed'],
    'Pokemon - Emerald Version',
    [
      'Pokemon - Glazed Version (Hack)',
      'Pokemon Glazed [Hack by Redriders180]',
    ],
  ),
  Romhack(
    'gba',
    ['blazedglazed'],
    'Pokemon - Emerald Version',
    ['Pokemon - Blazed Glazed Version (Hack)'],
  ),
  // Game Boy Advance, on FireRed.
  Romhack('gba', ['unbound'], 'Pokemon - FireRed Version'),
  Romhack('gba', ['radicalred'], 'Pokemon - FireRed Version'),
  Romhack('gba', ['gaia'], 'Pokemon - FireRed Version'),
  Romhack('gba', ['darkrising'], 'Pokemon - FireRed Version'),
  Romhack('gba', ['fireredomega', 'redomega'], 'Pokemon - FireRed Version'),
  Romhack('gba', [
    'fireredrocket',
    'rocketedition',
  ], 'Pokemon - FireRed Version'),
  Romhack('gba', ['elitered'], 'Pokemon - FireRed Version'),
  Romhack('gba', ['naturia'], 'Pokemon - FireRed Version'),
  Romhack('gba', ['quetzal'], 'Pokemon - Emerald Version'),
  Romhack(
    'gba',
    ['clover'],
    'Pokemon - FireRed Version',
    ['Pokemon Clover (Hack)'],
  ),
  Romhack(
    'gba',
    ['ashgray', 'ashgrey'],
    'Pokemon - FireRed Version',
    ['Pokemon - AshGray Version [Hack by metapod23]'],
  ),
  Romhack(
    'gba',
    ['liquidcrystal'],
    'Pokemon - FireRed Version',
    [
      'Pokemon - Liquid Crystal Version [Hack by linkandzelda]',
      'Pokemon - Liquid Crystal (Hack)',
    ],
  ),
  Romhack(
    'gba',
    ['ultrashinygoldsigma', 'shinygoldsigma', 'shinygold'],
    'Pokemon - FireRed Version',
    ['Pokemon - Ultra Shiny Gold Sigma (Hack)'],
  ),
  Romhack(
    'gba',
    ['adventuresredchapter', 'redchapter'],
    'Pokemon - FireRed Version',
    ['Pokemon Adventures - Red Chapter (Hack)'],
  ),
  // Game Boy Advance, on Ruby.
  Romhack('gba', ['lightplatinum'], 'Pokemon - Ruby Version'),
  // Game Boy Color, on Crystal.
  Romhack('gbc', ['polishedcrystal', 'polished'], 'Pokemon - Crystal Version'),
  Romhack('gbc', ['crystalclear'], 'Pokemon - Crystal Version'),
  Romhack('gbc', ['crystallegacy'], 'Pokemon - Crystal Version'),
  Romhack('gbc', ['crystalkaizo'], 'Pokemon - Crystal Version'),
  Romhack('gbc', ['perfectcrystal'], 'Pokemon - Crystal Version'),
  Romhack('gbc', ['prism'], 'Pokemon - Crystal Version'),
  Romhack('gbc', ['rijonadventures'], 'Pokemon - Crystal Version'),
  Romhack('gbc', ['orange'], 'Pokemon - Crystal Version'),
  // Game Boy, on Red.
  Romhack('gb', ['brown'], 'Pokemon - Red Version'),
  Romhack('gb', ['maize'], 'Pokemon - Red Version'),
];

/// The known romhack a ROM called [query] is, or null.
///
/// `Pokémon Polished Crystal 3.0.0.gbc`, `polishedcrystal-3.0.0.gbc` and
/// `Pokemon - Seaglass (v3.0)` all match: the [hackKey] is squashed (no
/// spaces), a leading `pokemon` is dropped, and a name must start it.
Romhack? romhackFor(String system, String query) {
  var key = hackKey(query).replaceAll(' ', '');
  if (key.startsWith('pokemon')) key = key.substring('pokemon'.length);
  Romhack? best;
  var bestLength = 0;
  for (final hack in romhacks) {
    if (hack.system != system) continue;
    for (final name in hack.names) {
      // Longest name wins: `blazedglazed` over `glazed`.
      if (name.length > bestLength && key.startsWith(name)) {
        best = hack;
        bestLength = name.length;
      }
    }
  }
  return best;
}

/// Whether a file or title says it is a hack (`(Hack)`, `romhack`, `kaizo`,
/// `[Hack by X]`).
bool looksLikeHack(String query) => RegExp(
  r'\b(rom ?hack|hack|kaizo)\b',
  caseSensitive: false,
).hasMatch(query.replaceAll('_', ' '));
