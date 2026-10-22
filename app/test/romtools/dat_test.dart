// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/rom-manager.md 1 and 6.1 (DAT parsing)
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:dena_emu/src/romtools/dat.dart';
import 'package:flutter_test/flutter_test.dart';

const xmlSample = '''<?xml version="1.0"?>
<!DOCTYPE datafile PUBLIC "-//Logiqx//DTD ROM Management Datafile//EN" "http://www.logiqx.com/dtds/datafile.dtd">
<datafile>
  <header>
    <name>Nintendo - Game Boy (Parent-Clone)</name>
    <version>20240101-000000</version>
  </header>
  <game name="Alpha &amp; Beta (USA)">
    <description>Alpha &amp; Beta (USA)</description>
    <rom name="Alpha &amp; Beta (USA).gb" size="32768" crc="ABCD1234" md5="00112233445566778899AABBCCDDEEFF" sha1="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"/>
  </game>
  <machine name="Gamma &quot;Q&quot; &#65;(Japan)">
    <rom sha1="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" status="baddump" crc="11112222" size="65536" name="Gamma.gb"/>
  </machine>
</datafile>
''';

const cmpSample = '''clrmamepro (
\tname "Nintendo - Game Boy (Parent-Clone)"
\tdescription "Nintendo - Game Boy"
\tversion 20240101-000000
)

game (
\tname "Alpha & Beta (USA)"
\tdescription "Alpha & Beta (USA)"
\trom ( name "Alpha & Beta (USA).gb" size 32768 crc ABCD1234 md5 00112233445566778899AABBCCDDEEFF sha1 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA )
)

game (
\tname "Gamma \\"Q\\" A(Japan)"
\trom ( name "Gamma.gb" size 65536 crc 11112222 sha1 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb flags baddump )
)
''';

List<String> _entries(DatFile dat) => [
  for (final g in dat.games)
    for (final r in g.roms)
      '${g.name}|${r.name}|${r.size}|${r.crc32}|${r.md5}|${r.sha1}|${r.badDump}',
];

void main() {
  test('XML and ClrMamePro samples give the same entries', () {
    final xml = DatFile.parse(xmlSample);
    final cmp = DatFile.parse(cmpSample);
    expect(xml.name, 'Nintendo - Game Boy (Parent-Clone)');
    expect(cmp.name, xml.name);
    expect(xml.version, '20240101-000000');
    expect(cmp.version, xml.version);
    expect(_entries(xml), _entries(cmp));
    expect(_entries(xml), [
      'Alpha & Beta (USA)|Alpha & Beta (USA).gb|32768|abcd1234|'
          '00112233445566778899aabbccddeeff|'
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|false',
      'Gamma "Q" A(Japan)|Gamma.gb|65536|11112222|null|'
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|true',
    ]);
  });

  test('ClrMamePro status baddump marks a bad dump', () {
    final dat = DatFile.parse(
      'game ( name "X" rom ( name "x.nes" size 1 crc 00000001 '
      'status baddump ) )',
    );
    expect(dat.name, '');
    expect(dat.games.single.roms.single.badDump, isTrue);
  });

  test('anything else is not a DAT', () {
    for (final text in ['', 'hello world', '<html><body/></html>', '{}']) {
      expect(
        () => DatFile.parse(text),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Not a DAT file',
          ),
        ),
      );
    }
  });

  test('a zip holding one DAT is unpacked; latin1 falls back', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('readme.txt', utf8.encode('hi')))
      ..addFile(ArchiveFile.bytes('gb.dat', utf8.encode(cmpSample)));
    final zip = ZipEncoder().encode(archive);
    expect(
      _entries(DatFile.parseBytes(zip)),
      _entries(DatFile.parse(cmpSample)),
    );

    final latin = latin1.encode('game ( name "Pokémon" rom ( name "p.gb" ) )');
    expect(DatFile.parseBytes(latin).games.single.name, 'Pokémon');
    final bom = [0xef, 0xbb, 0xbf, ...utf8.encode(xmlSample)];
    expect(DatFile.parseBytes(bom).games, hasLength(2));
  });

  group('DatIndex', () {
    final index = DatIndex(DatFile.parse(xmlSample));

    test('by SHA-1, any case', () {
      expect(
        index.bySha1('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')?.game.name,
        'Alpha & Beta (USA)',
      );
      expect(index.bySha1('cccc'), isNull);
    });

    test('by CRC and size', () {
      expect(index.byCrc('abcd1234', 32768)?.rom.name, 'Alpha & Beta (USA).gb');
      expect(index.byCrc('ABCD1234', 32768), isNotNull);
      expect(index.byCrc('abcd1234', 1), isNull);
      final noSize = DatIndex(
        DatFile.parse('game ( name "N" rom ( name "n.gb" crc 0000000F ) )'),
      );
      expect(noSize.byCrc('0000000f', 99)?.game.name, 'N');
    });

    test('by file name', () {
      expect(
        index.byFileName('alpha & beta (usa).zip')?.name,
        'Alpha & Beta (USA)',
      );
      expect(index.byFileName('Gamma.gbc')?.name, 'Gamma "Q" A(Japan)');
      expect(index.byFileName('Gamma.p8.png')?.name, 'Gamma "Q" A(Japan)');
      expect(index.byFileName('Delta (USA).gb'), isNull);
    });
  });

  test('a big DAT parses quickly', () {
    final buf = StringBuffer('clrmamepro ( name "Nintendo - Nintendo DS" )\n');
    for (var i = 0; i < 60000; i++) {
      final h = i.toRadixString(16).padLeft(8, '0');
      buf.write(
        'game (\n\tname "Game $i (USA)"\n\tdescription "Game $i (USA)"\n'
        '\trom ( name "Game $i (USA).nds" size ${i * 512} crc $h '
        'md5 ${h * 4} sha1 ${h * 5} )\n)\n\n',
      );
    }
    final watch = Stopwatch()..start();
    final dat = DatFile.parse(buf.toString());
    final index = DatIndex(dat);
    expect(dat.games, hasLength(60000));
    expect(
      index.byCrc('0000ea5f', 0xea5f * 512)?.game.name,
      'Game 59999 (USA)',
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
