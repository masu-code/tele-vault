// Aes256 block cipher + SHA-256 backend: known-answer and differential tests.
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';
import 'package:tg/src/crypto/aes256.dart';
import 'package:tg/src/crypto/backend.dart';
import 'package:tg/src/crypto/dart_backend.dart';

import '../tool/gen_goldens.dart' show hex, unhex;

void main() {
  test('FIPS-197 C.3 (AES-256) encrypt and decrypt', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final pt = unhex('00112233445566778899aabbccddeeff');
    final ct = unhex('8ea2b7ca516745bfeafc49904b496089');
    final aes = Aes256(key);
    expect(hex(aes.encryptBlockBytes(pt)), hex(ct));
    expect(hex(aes.decryptBlockBytes(ct)), hex(pt));
  });

  test('FIPS-197 appendix F style: all-zero key, all-zero block', () {
    // Known value for AES-256, key = 0^32, pt = 0^16.
    final aes = Aes256(Uint8List(32));
    expect(hex(aes.encryptBlockBytes(Uint8List(16))),
        'dc95c078a2408989ad48a21492842087');
  });

  test('10k random blocks match pointycastle (encrypt and decrypt)', () {
    final r = Random(1101);
    Uint8List rb(int n) =>
        Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
    for (var k = 0; k < 20; k++) {
      final key = rb(32);
      final aes = Aes256(key);
      final enc = pc.AESEngine()..init(true, pc.KeyParameter(key));
      final dec = pc.AESEngine()..init(false, pc.KeyParameter(key));
      for (var i = 0; i < 500; i++) {
        final b = rb(16);
        final expE = Uint8List(16);
        enc.processBlock(b, 0, expE, 0);
        expect(aes.encryptBlockBytes(b), expE, reason: 'enc key $k block $i');
        final expD = Uint8List(16);
        dec.processBlock(b, 0, expD, 0);
        expect(aes.decryptBlockBytes(b), expD, reason: 'dec key $k block $i');
      }
    }
  });

  test('block functions work in place on a Uint32List', () {
    final key = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    final aes = Aes256(key);
    final buf = Uint8List.fromList(List.generate(64, (i) => i * 3));
    final w = buf.buffer.asUint32List();
    final orig = Uint8List.fromList(buf);
    for (var i = 0; i < 16; i += 4) {
      aes.encryptBlock(w, i, w, i);
    }
    expect(buf, isNot(orig));
    for (var i = 0; i < 16; i += 4) {
      aes.decryptBlock(w, i, w, i);
    }
    expect(buf, orig);
  });

  test('rejects a wrong key length', () {
    expect(() => Aes256(Uint8List(16)), throwsArgumentError);
  });

  group('SHA-256 (DartCryptoBackend)', () {
    final be = DartCryptoBackend();
    test('abc', () {
      final out = Uint8List(32);
      be.sha256(Uint8List.fromList('abc'.codeUnits), 0, 3, out, 0);
      expect(hex(out),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
    test('offset view and output offset', () {
      final data = Uint8List.fromList([9, 9, ...'abc'.codeUnits, 7]);
      final out = Uint8List(40);
      be.sha256(data, 2, 3, out, 5);
      expect(hex(out.sublist(5, 37)),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(out.sublist(0, 5), everyElement(0));
      expect(out.sublist(37), everyElement(0));
    });
    test('empty input', () {
      final out = Uint8List(32);
      be.sha256(Uint8List(0), 0, 0, out, 0);
      expect(hex(out),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });
  });

  // T2.2: the default is resolved at first use (native or dart).
  test('TgCrypto default backend is restored by resetForTesting', () {
    final def = TgCrypto.backend.name;
    expect(def, isIn(['dart', 'native']));
    TgCrypto.backend = _Named('other');
    expect(TgCrypto.backend.name, 'other');
    TgCrypto.resetForTesting();
    expect(TgCrypto.backend.name, def);
  });
}

class _Named implements TgCryptoBackend {
  _Named(this.name);
  @override
  final String name;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
