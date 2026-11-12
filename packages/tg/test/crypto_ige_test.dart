// AES-256-IGE of the pure-Dart backend: goldens, reference copy, independent
// implementation, views/offsets and in-place operation.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';
import 'package:tg/src/crypto/backend.dart';
import 'package:tg/src/crypto/dart_backend.dart';

import '../tool/gen_goldens.dart' show detBytes, hex, sha256Hex, unhex;
import '../tool/reference/tg_0_0_20_reference.dart';

/// Straightforward IGE built on pointycastle's ECB, written independently of
/// the code under test and of the tg reference.
Uint8List slowIge(bool encrypt, Uint8List key, Uint8List iv32, Uint8List data) {
  final engine = pc.AESEngine()..init(encrypt, pc.KeyParameter(key));
  var cPrev = Uint8List.fromList(iv32.sublist(0, 16));
  var pPrev = Uint8List.fromList(iv32.sublist(16, 32));
  final out = Uint8List(data.length);
  final tmp = Uint8List(16);
  final res = Uint8List(16);
  for (var o = 0; o < data.length; o += 16) {
    final block = data.sublist(o, o + 16);
    if (encrypt) {
      for (var i = 0; i < 16; i++) {
        tmp[i] = block[i] ^ cPrev[i];
      }
      engine.processBlock(tmp, 0, res, 0);
      for (var i = 0; i < 16; i++) {
        res[i] ^= pPrev[i];
      }
      out.setRange(o, o + 16, res);
      cPrev = Uint8List.fromList(res);
      pPrev = block;
    } else {
      for (var i = 0; i < 16; i++) {
        tmp[i] = block[i] ^ pPrev[i];
      }
      engine.processBlock(tmp, 0, res, 0);
      for (var i = 0; i < 16; i++) {
        res[i] ^= cPrev[i];
      }
      out.setRange(o, o + 16, res);
      pPrev = Uint8List.fromList(res);
      cPrev = block;
    }
  }
  return out;
}

Uint8List run(TgCryptoBackend be, bool enc, Uint8List key, Uint8List iv,
    Uint8List input) {
  final out = Uint8List(input.length);
  be.aesIge(
      encrypt: enc,
      key32: key,
      iv32: iv,
      input: input,
      inOffset: 0,
      length: input.length,
      output: out,
      outOffset: 0);
  return out;
}

void main() {
  final be = DartCryptoBackend();
  final g = jsonDecode(
          utf8.decode(File('test/goldens/tg_0_0_20_goldens.json').readAsBytesSync()))
      as Map<String, dynamic>;

  test('goldens: 40 explicit IGE cases', () {
    final cases = (g['ige'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, 40);
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final out = run(be, c['encrypt'] as bool, unhex(c['key']), unhex(c['iv']),
          unhex(c['input']));
      expect(hex(out), c['output'], reason: 'ige case $i');
    }
  });

  test('goldens: 64 KiB and 1 MiB (sha256)', () {
    for (final c in (g['igeBig'] as List).cast<Map<String, dynamic>>()) {
      final input = detBytes(c['inputSeed'], c['len']);
      final out = run(be, c['encrypt'] as bool, unhex(c['key']),
          unhex(c['iv']), input);
      expect(sha256Hex(out), c['outputSha256'], reason: 'len ${c['len']}');
    }
  });

  test('matches the frozen reference copy (random keys, ivs, lengths)', () {
    final r = Random(2001);
    for (var n = 0; n < 60; n++) {
      final len = 16 * (1 + r.nextInt(300));
      final key = detBytes(100 + n, 32);
      final iv = detBytes(200 + n, 32);
      final data = detBytes(300 + n, len);
      for (final enc in [true, false]) {
        final exp = refAesIgeEncryptDecrypt(
            Uint8List.fromList(data), RefAesKeyIV(key, iv), enc);
        expect(run(be, enc, key, iv, data), exp, reason: 'n=$n len=$len enc=$enc');
      }
    }
  });

  test('matches an independent IGE built on pointycastle ECB', () {
    final r = Random(2002);
    for (var n = 0; n < 40; n++) {
      final len = 16 * (1 + r.nextInt(64));
      final key = detBytes(400 + n, 32);
      final iv = detBytes(500 + n, 32);
      final data = detBytes(600 + n, len);
      for (final enc in [true, false]) {
        expect(run(be, enc, key, iv, data), slowIge(enc, key, iv, data),
            reason: 'n=$n enc=$enc');
      }
    }
  });

  test('encrypt then decrypt round-trips (1 MiB)', () {
    final key = detBytes(1, 32), iv = detBytes(2, 32);
    final data = detBytes(3, 1 << 20);
    final ct = run(be, true, key, iv, data);
    expect(ct, isNot(data));
    expect(run(be, false, key, iv, ct), data);
  });

  test('views at every offset 0..7 (input and output independently)', () {
    final key = detBytes(7, 32), iv = detBytes(8, 32);
    const len = 16 * 33;
    final plain = detBytes(9, len);
    for (final enc in [true, false]) {
      final exp = slowIge(enc, key, iv, plain);
      for (var io = 0; io < 8; io++) {
        for (var oo = 0; oo < 8; oo++) {
          final src = Uint8List(len + 20);
          src.setRange(io, io + len, plain);
          final dst = Uint8List(len + 20)..fillRange(0, len + 20, 0xEE);
          be.aesIge(
              encrypt: enc,
              key32: key,
              iv32: iv,
              input: src,
              inOffset: io,
              length: len,
              output: dst,
              outOffset: oo);
          expect(dst.sublist(oo, oo + len), exp, reason: 'enc=$enc in=$io out=$oo');
          // Bytes outside the output range are untouched.
          expect(dst.sublist(0, oo), everyElement(0xEE));
          expect(dst.sublist(oo + len), everyElement(0xEE));
        }
      }
    }
  });

  test('sublistView inputs with a non-zero offsetInBytes', () {
    final key = detBytes(11, 32), iv = detBytes(12, 32);
    final big = detBytes(13, 4096);
    for (final start in [1, 2, 3, 4, 5, 24, 25]) {
      final view = Uint8List.sublistView(big, start, start + 256);
      final out = Uint8List(256);
      be.aesIge(
          encrypt: true,
          key32: key,
          iv32: iv,
          input: view,
          inOffset: 0,
          length: 256,
          output: out,
          outOffset: 0);
      expect(out, slowIge(true, key, iv, Uint8List.fromList(view)),
          reason: 'start=$start');
    }
  });

  test('in place (same buffer and offset), aligned and unaligned', () {
    final key = detBytes(21, 32), iv = detBytes(22, 32);
    for (final off in [0, 1, 3, 4, 8, 13]) {
      for (final enc in [true, false]) {
        final plain = detBytes(23 + off, 16 * 20);
        final buf = Uint8List(plain.length + 32)..fillRange(0, plain.length + 32, 0x5A);
        buf.setRange(off, off + plain.length, plain);
        be.aesIge(
            encrypt: enc,
            key32: key,
            iv32: iv,
            input: buf,
            inOffset: off,
            length: plain.length,
            output: buf,
            outOffset: off);
        expect(buf.sublist(off, off + plain.length), slowIge(enc, key, iv, plain),
            reason: 'off=$off enc=$enc');
        expect(buf.sublist(0, off), everyElement(0x5A));
        expect(buf.sublist(off + plain.length), everyElement(0x5A));
      }
    }
  });

  test('partially overlapping input/output in one buffer behaves like a copy', () {
    final key = detBytes(31, 32), iv = detBytes(32, 32);
    final plain = detBytes(33, 16 * 8);
    final buf = Uint8List(plain.length + 64);
    buf.setRange(0, plain.length, plain);
    be.aesIge(
        encrypt: true,
        key32: key,
        iv32: iv,
        input: buf,
        inOffset: 0,
        length: plain.length,
        output: buf,
        outOffset: 16);
    expect(buf.sublist(16, 16 + plain.length), slowIge(true, key, iv, plain));
  });

  test('iv32 may be a view; key and iv are not modified', () {
    final key = detBytes(41, 32);
    final ivBig = detBytes(42, 40);
    final iv = Uint8List.sublistView(ivBig, 3, 35);
    final keyCopy = Uint8List.fromList(key), ivCopy = Uint8List.fromList(iv);
    final data = detBytes(43, 160);
    expect(run(be, true, key, iv, data), slowIge(true, key, ivCopy, data));
    expect(key, keyCopy);
    expect(iv, ivCopy);
  });

  test('argument checks', () {
    final key = Uint8List(32), iv = Uint8List(32);
    final buf = Uint8List(64);
    void call({int length = 16, Uint8List? ivv, int inOff = 0, int outOff = 0}) =>
        be.aesIge(
            encrypt: true,
            key32: key,
            iv32: ivv ?? iv,
            input: buf,
            inOffset: inOff,
            length: length,
            output: buf,
            outOffset: outOff);
    expect(() => call(length: 15), throwsArgumentError);
    expect(() => call(ivv: Uint8List(16)), throwsArgumentError);
    expect(() => call(length: 80), throwsRangeError);
    expect(() => call(inOff: 60), throwsRangeError);
    expect(() => call(outOff: 60), throwsRangeError);
    expect(() => call(length: 0), returnsNormally);
    expect(
        () => be.aesIge(
            encrypt: true,
            key32: Uint8List(31),
            iv32: iv,
            input: buf,
            inOffset: 0,
            length: 16,
            output: buf,
            outOffset: 0),
        throwsArgumentError);
  });
}
