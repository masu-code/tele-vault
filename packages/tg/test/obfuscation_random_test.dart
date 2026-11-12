// T1.3(h): `Obfuscation.random` uses a CSPRNG and only emits preambles that
// satisfy the MTProto transport obfuscation constraints.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg/tg.dart';

const _forbiddenFirstWords = <int>[
  0x44414548, // HEAD
  0x54534F50, // POST
  0x20544547, // GET
  0x4954504F, // OPTI
  0x02010316, // TLS
  0xDDDDDDDD,
  0xEEEEEEEE,
];

void _expectValid(Uint8List p, String why) {
  final bd = ByteData.sublistView(p);
  expect(p[0], isNot(0xEF), reason: why);
  expect(_forbiddenFirstWords, isNot(contains(bd.getUint32(0, Endian.little))),
      reason: why);
  expect(bd.getUint32(4, Endian.little), isNot(0), reason: why);
}

void main() {
  test('10k random preambles satisfy the constraints and are all distinct', () {
    final seen = <String>{};
    final counts = List<int>.filled(256, 0);
    for (var i = 0; i < 10000; i++) {
      final o = Obfuscation.random(i.isEven, 1 + i % 5);
      final p = o.preamble;
      expect(p.length, 64);
      _expectValid(p, 'preamble $i');
      // Bytes 56..59 carry the (encrypted) protocol tag, 60..61 the dc id.
      seen.add(String.fromCharCodes(p.sublist(0, 56)));
      for (var k = 8; k < 56; k++) {
        counts[p[k]]++;
      }
    }
    expect(seen.length, 10000);
    // 480k bytes: every value ~1875 times. A constant or (i+1)%256 generator
    // fails this immediately.
    for (var v = 0; v < 256; v++) {
      expect(counts[v], inInclusiveRange(1500, 2250), reason: 'byte $v');
    }
  });

  test('the predicate rejects every forbidden pattern', () {
    Uint8List base() {
      final b = Uint8List(58);
      for (var i = 0; i < 58; i++) {
        b[i] = 0x10 + i;
      }
      return b;
    }

    expect(TgInternals.obfuscationRandomIsValid(base()), isTrue);

    expect(TgInternals.obfuscationRandomIsValid(base()..[0] = 0xEF), isFalse);

    for (final w in _forbiddenFirstWords) {
      final b = base();
      ByteData.sublistView(b).setUint32(0, w, Endian.little);
      expect(TgInternals.obfuscationRandomIsValid(b), isFalse,
          reason: w.toRadixString(16));
    }

    final zero4 = base();
    ByteData.sublistView(zero4).setUint32(4, 0, Endian.little);
    expect(TgInternals.obfuscationRandomIsValid(zero4), isFalse);

    // Near misses stay valid.
    final b1 = base()..[0] = 0xEE; // EE 11 12 13 is not EEEEEEEE
    expect(TgInternals.obfuscationRandomIsValid(b1), isTrue);
    final b2 = base();
    ByteData.sublistView(b2).setUint32(4, 1, Endian.little);
    expect(TgInternals.obfuscationRandomIsValid(b2), isTrue);
  });
}
