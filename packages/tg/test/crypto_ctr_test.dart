// AES-256-CTR of the pure-Dart backend: SP800-38A, goldens, pointycastle.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';
import 'package:tg/src/crypto/dart_backend.dart';

import '../tool/gen_goldens.dart' show detBytes, hex, sha256Hex, unhex;

Uint8List pcCtr(Uint8List key, Uint8List iv, Uint8List data) {
  final c = pc.StreamCipher('AES/CTR')
    ..init(true, pc.ParametersWithIV(pc.KeyParameter(key), iv));
  return c.process(Uint8List.fromList(data));
}

void main() {
  final be = DartCryptoBackend();

  test('SP800-38A F.5.5 CTR-AES256.Encrypt (4 blocks, 1 call and byte by byte)', () {
    final key = unhex(
        '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4');
    final iv = unhex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
    final pt = unhex('6bc1bee22e409f96e93d7e117393172a'
        'ae2d8a571e03ac9c9eb76fac45af8e51'
        '30c81c46a35ce411e5fbc1191a0a52ef'
        'f69f2445df4f9b17ad2b417be66c3710');
    final ct = '601ec313775789a5b7a7f504bbf3d228'
        'f443e3ca4d62b59aca84e990cacaf5c5'
        '2b0930daa23de94ce87017ba2d84988d'
        'dfc9c58db67aada613c2dd08457941a6';
    final a = Uint8List.fromList(pt);
    final s1 = be.createCtr(key, iv)..process(a, 0, a.length);
    expect(hex(a), ct);
    s1.dispose();

    final b = Uint8List.fromList(pt);
    final s2 = be.createCtr(key, iv);
    for (var i = 0; i < b.length; i++) {
      s2.process(b, i, 1);
    }
    expect(hex(b), ct);
    // Decrypt = encrypt with a fresh stream.
    be.createCtr(key, iv).process(b, 0, b.length);
    expect(hex(b), hex(pt));
  });

  test('goldens: 27 chunk-pattern cases (incl. all-ff counter wrap)', () {
    final g = jsonDecode(utf8.decode(
            File('test/goldens/tg_0_0_20_goldens.json').readAsBytesSync()))
        as Map<String, dynamic>;
    final cases = (g['ctr'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, 27);
    for (final c in cases) {
      final total = c['total'] as int;
      final chunks = List<int>.from(c['chunks'] as List);
      final input = detBytes(c['inputSeed'], total);
      final s = be.createCtr(unhex(c['key']), unhex(c['iv']));
      var pos = 0, ci = 0;
      while (pos < total) {
        final size = min(chunks[ci++ % chunks.length], total - pos);
        s.process(input, pos, size); // in place inside the big buffer
        pos += size;
      }
      final why = 'iv ${c['ivKind']} chunks $chunks';
      expect(sha256Hex(input), c['outputSha256'], reason: why);
      if (c.containsKey('output')) expect(hex(input), c['output'], reason: why);
    }
  });

  test('random splits vs pointycastle, at all view offsets', () {
    final r = Random(3001);
    for (var n = 0; n < 60; n++) {
      final key = detBytes(700 + n, 32);
      final iv = detBytes(800 + n, 16);
      final total = 1 + r.nextInt(5000);
      final data = detBytes(900 + n, total);
      final exp = pcCtr(key, iv, data);
      final pad = r.nextInt(8);
      final buf = Uint8List(total + 16);
      buf.setRange(pad, pad + total, data);
      final s = be.createCtr(key, iv);
      var pos = 0;
      while (pos < total) {
        final size = min(1 + r.nextInt(r.nextBool() ? 40 : 700), total - pos);
        s.process(buf, pad + pos, size);
        pos += size;
      }
      expect(buf.sublist(pad, pad + total), exp, reason: 'n=$n pad=$pad');
    }
  });

  test('counter wrap: iv ff..ff and carries across byte boundaries', () {
    final key = detBytes(51, 32);
    for (final ivHex in [
      'ff' * 16,
      '${'00' * 8}${'ff' * 8}',
      '${'12' * 7}fe${'ff' * 8}',
      '${'00' * 15}ff',
      '${'00' * 14}ffff',
    ]) {
      final iv = unhex(ivHex);
      final data = detBytes(52, 16 * 6 + 5);
      final buf = Uint8List.fromList(data);
      be.createCtr(key, iv).process(buf, 0, buf.length);
      expect(buf, pcCtr(key, iv, data), reason: 'iv $ivHex');
    }
  });

  test('zero-length process is a no-op and keeps the keystream position', () {
    final key = detBytes(61, 32), iv = detBytes(62, 16);
    final data = detBytes(63, 100);
    final buf = Uint8List.fromList(data);
    final s = be.createCtr(key, iv);
    s.process(buf, 0, 7);
    s.process(buf, 7, 0);
    s.process(buf, 7, 93);
    expect(buf, pcCtr(key, iv, data));
  });

  test('argument checks and use after dispose', () {
    final key = detBytes(71, 32), iv = detBytes(72, 16);
    expect(() => be.createCtr(Uint8List(16), iv), throwsArgumentError);
    expect(() => be.createCtr(key, Uint8List(15)), throwsArgumentError);
    final s = be.createCtr(key, iv);
    expect(() => s.process(Uint8List(8), 4, 8), throwsRangeError);
    s.dispose();
    s.dispose(); // idempotent
    expect(() => s.process(Uint8List(8), 0, 8), throwsStateError);
  });
}
