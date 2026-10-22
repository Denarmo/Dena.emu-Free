import 'package:dena_emu/src/session/cheat_codes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void accepts(String system, String input, List<String> lines, String format) {
    final c = parseCheat(system, input);
    expect(c, isNotNull, reason: '$system $input');
    expect(c!.lines, lines);
    expect(c.format, format);
  }

  test('NES Game Genie and raw codes', () {
    accepts('nes', 'sxiopo', ['SXIOPO'], 'Game Genie');
    accepts('nes', 'YEUZUGAA', ['YEUZUGAA'], 'Game Genie');
    accepts('nes', '075A:05', ['075A:05'], 'Raw');
    accepts('nes', '075a?01:05', ['075A?01:05'], 'Raw');
    expect(parseCheat('nes', 'SXIOP'), isNull);
    expect(parseCheat('nes', 'BBBBBB'), isNull); // B is not a Game Genie letter
  });

  test('SNES Game Genie needs the dash; Pro Action Replay does not', () {
    accepts('snes', 'df6a-d4d6', ['DF6A-D4D6'], 'Game Genie');
    accepts('snes', '7E0DBF09', ['7E0DBF09'], 'Pro Action Replay');
    expect(parseCheat('snes', '7E0DBF0'), isNull);
  });

  test('Game Boy Game Genie and GameShark', () {
    accepts('gb', '00A-17B', ['00A-17B'], 'Game Genie');
    accepts('gbc', '00a17bc3b', ['00A-17B-C3B'], 'Game Genie');
    accepts('gb', '01ff16d0', ['01FF16D0'], 'GameShark');
    expect(parseCheat('gb', '01FF16D'), isNull);
  });

  test('GBA multi-line codes are joined with + for the core', () {
    final c = parseCheat('gba', '82003DF4 0063\n12345678 9abcdef0')!;
    expect(c.lines, ['82003DF4 0063', '12345678 9ABCDEF0']);
    expect(c.format, 'Mixed');
    expect(coreCode(c.stored), '82003DF4 0063+12345678 9ABCDEF0');
    accepts('gba', '1234567890ABCDEF', [
      '12345678 90ABCDEF',
    ], 'GameShark / Action Replay');
  });

  test('PSP CWCheat lines, with or without _L', () {
    expect(parseCheat('psp', '0x20000004 0x1'), isNull);
    final ok = parseCheat(
      'psp',
      '_L 0x2012abcd 0x00000063\n0x20000004 0x00000001',
    )!;
    expect(ok.lines, ['0x2012ABCD 0x00000063', '0x20000004 0x00000001']);
    expect(ok.format, 'CWCheat');
    expect(coreCode(ok.stored), '0x2012ABCD 0x00000063+0x20000004 0x00000001');
  });

  test('blank input, unknown systems and any bad line are rejected', () {
    expect(parseCheat('nes', '  \n '), isNull);
    expect(parseCheat('psx', '12345678'), isNull);
    expect(parseCheat('nes', 'SXIOPO\nnope'), isNull);
  });
}
