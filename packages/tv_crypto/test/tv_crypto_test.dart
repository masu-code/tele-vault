import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';
import 'package:tv_crypto/src/bindings.dart' as b;
import 'package:tv_crypto/tv_crypto.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> v) =>
    v.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List rnd(Random r, int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

/// Straightforward IGE over pointycastle's AES block cipher (reference).
Uint8List refIge(bool encrypt, Uint8List key, Uint8List iv, Uint8List input) {
  final aes = pc.AESEngine()..init(encrypt, pc.KeyParameter(key));
  final out = Uint8List(input.length);
  var x = Uint8List.fromList(iv.sublist(0, 16)); // c_prev
  var y = Uint8List.fromList(iv.sublist(16, 32)); // p_prev
  final t = Uint8List(16);
  final o = Uint8List(16);
  for (var off = 0; off < input.length; off += 16) {
    final blk = Uint8List.fromList(input.sublist(off, off + 16));
    if (encrypt) {
      for (var i = 0; i < 16; i++) {
        t[i] = blk[i] ^ x[i];
      }
      aes.processBlock(t, 0, o, 0);
      for (var i = 0; i < 16; i++) {
        o[i] ^= y[i];
      }
      out.setRange(off, off + 16, o);
      x = Uint8List.fromList(o);
      y = blk;
    } else {
      for (var i = 0; i < 16; i++) {
        t[i] = blk[i] ^ y[i];
      }
      aes.processBlock(t, 0, o, 0);
      for (var i = 0; i < 16; i++) {
        o[i] ^= x[i];
      }
      out.setRange(off, off + 16, o);
      x = blk;
      y = Uint8List.fromList(o);
    }
  }
  return out;
}

Uint8List refCtr(Uint8List key, Uint8List iv, Uint8List input) {
  final c = pc.CTRStreamCipher(pc.AESEngine())
    ..init(true, pc.ParametersWithIV(pc.KeyParameter(key), iv));
  final out = Uint8List(input.length);
  c.processBytes(input, 0, input.length, out, 0);
  return out;
}

Uint8List refSha(Uint8List data) => pc.SHA256Digest().process(data);

void main() {
  final crypto = TvCrypto.tryLoad();

  test('library loads and passes its self-test', () {
    expect(crypto, isNotNull);
    final info = crypto!.info;
    // ignore: avoid_print
    print('tv_crypto info=0x${info.toRadixString(16)} '
        'aesAvail=${info & TvCryptoInfo.aesAccelAvailable != 0} '
        'aesActive=${info & TvCryptoInfo.aesAccelActive != 0} '
        'shaAvail=${info & TvCryptoInfo.shaAccelAvailable != 0} '
        'shaActive=${info & TvCryptoInfo.shaAccelActive != 0}');
    expect(info & TvCryptoInfo.selfTestFailed, 0);
    expect(info & TvCryptoInfo.portableFailed, 0);
    expect(b.tvcVersion(), TvCrypto.expectedVersion);
  });

  test('C argument checks return -1', () {
    final key = Uint8List(32);
    final iv = Uint8List(32);
    final buf = Uint8List(32);
    expect(
      b.tvcAes256Ige(1, nullptr, iv.address, buf.address, buf.address, 16),
      -1,
    );
    expect(
      b.tvcAes256Ige(1, key.address, nullptr, buf.address, buf.address, 16),
      -1,
    );
    expect(
      b.tvcAes256Ige(1, key.address, iv.address, nullptr, buf.address, 16),
      -1,
    );
    expect(
      b.tvcAes256Ige(1, key.address, iv.address, buf.address, nullptr, 16),
      -1,
    );
    expect(
      b.tvcAes256Ige(1, key.address, iv.address, buf.address, buf.address, 15),
      -1,
    );
    expect(
      b.tvcAes256Ige(1, key.address, iv.address, buf.address, buf.address, 0),
      0,
    );
    expect(b.tvcAes256CtrInit(nullptr, key.address, iv.address), -1);
  });

  test('Dart argument checks', () {
    final c = crypto!;
    final k = Uint8List(32);
    final buf = Uint8List(64);
    expect(
      () => c.aesIge(
        encrypt: true,
        key32: Uint8List(16),
        iv32: k,
        input: buf,
        inOffset: 0,
        length: 16,
        output: buf,
        outOffset: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => c.aesIge(
        encrypt: true,
        key32: k,
        iv32: k,
        input: buf,
        inOffset: 0,
        length: 17,
        output: buf,
        outOffset: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => c.aesIge(
        encrypt: true,
        key32: k,
        iv32: k,
        input: buf,
        inOffset: 32,
        length: 48,
        output: buf,
        outOffset: 0,
      ),
      throwsRangeError,
    );
    // Partial overlap is rejected, identical in-place is fine.
    expect(
      () => c.aesIge(
        encrypt: true,
        key32: k,
        iv32: k,
        input: buf,
        inOffset: 0,
        length: 32,
        output: buf,
        outOffset: 16,
      ),
      throwsArgumentError,
    );
    c.aesIge(
      encrypt: true,
      key32: k,
      iv32: k,
      input: buf,
      inOffset: 16,
      length: 32,
      output: Uint8List.sublistView(buf, 16),
      outOffset: 0,
    );
    final ctr = c.createCtr(k, Uint8List(16));
    ctr.dispose();
    ctr.dispose();
    expect(() => ctr.process(buf, 0, 1), throwsStateError);
    expect(() => c.createCtr(k, Uint8List(15)), throwsArgumentError);
  });

  for (final portable in [true, false]) {
    group(portable ? 'portable' : 'accelerated-if-available', () {
      setUp(() => crypto!.forcePortableForTesting(portable));
      tearDown(() => crypto!.forcePortableForTesting(false));

      test('forcePortable reflected in info', () {
        final info = crypto!.info;
        if (portable) {
          expect(info & TvCryptoInfo.aesAccelActive, 0);
          expect(info & TvCryptoInfo.shaAccelActive, 0);
        } else {
          expect(
            info & TvCryptoInfo.aesAccelActive != 0,
            info & TvCryptoInfo.aesAccelAvailable != 0,
          );
          expect(
            info & TvCryptoInfo.shaAccelActive != 0,
            info & TvCryptoInfo.shaAccelAvailable != 0,
          );
        }
      });

      test('FIPS-197 C.3 (AES-256) via IGE with zero IV', () {
        final key = hex('000102030405060708090a0b0c0d0e0f'
            '101112131415161718191a1b1c1d1e1f');
        final pt = hex('00112233445566778899aabbccddeeff');
        final ct = hex('8ea2b7ca516745bfeafc49904b496089');
        final iv = Uint8List(32);
        final out = Uint8List(16);
        crypto!.aesIge(
          encrypt: true,
          key32: key,
          iv32: iv,
          input: pt,
          inOffset: 0,
          length: 16,
          output: out,
          outOffset: 0,
        );
        expect(toHex(out), toHex(ct));
        crypto.aesIge(
          encrypt: false,
          key32: key,
          iv32: iv,
          input: ct,
          inOffset: 0,
          length: 16,
          output: out,
          outOffset: 0,
        );
        expect(toHex(out), toHex(pt));
      });

      test('SP800-38A F.5.5 CTR-AES256.Encrypt', () {
        final key = hex('603deb1015ca71be2b73aef0857d7781'
            '1f352c073b6108d72d9810a30914dff4');
        final iv = hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff');
        final pt = hex('6bc1bee22e409f96e93d7e117393172a'
            'ae2d8a571e03ac9c9eb76fac45af8e51'
            '30c81c46a35ce411e5fbc1191a0a52ef'
            'f69f2445df4f9b17ad2b417be66c3710');
        final ct = hex('601ec313775789a5b7a7f504bbf3d228'
            'f443e3ca4d62b59aca84e990cacaf5c5'
            '2b0930daa23de94ce87017ba2d84988d'
            'dfc9c58db67aada613c2dd08457941a6');
        // Whole, then byte-split (1 + 15 + 17 + 31).
        final ctr = crypto!.createCtr(key, iv);
        final a = Uint8List.fromList(pt);
        ctr.process(a, 0, a.length);
        ctr.dispose();
        expect(toHex(a), toHex(ct));
        final ctr2 = crypto.createCtr(key, iv);
        final b2 = Uint8List.fromList(pt);
        var off = 0;
        for (final n in [1, 15, 17, 31]) {
          ctr2.process(b2, off, n);
          off += n;
        }
        ctr2.dispose();
        expect(toHex(b2), toHex(ct));
      });

      test('SHA-256 known answers', () {
        final out = Uint8List(32);
        void sha(List<int> data) => crypto!.sha256(
          Uint8List.fromList(data),
          0,
          data.length,
          out,
        );
        sha('abc'.codeUnits);
        expect(
          toHex(out),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        );
        sha(const []);
        expect(
          toHex(out),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        );
        sha('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'
            .codeUnits);
        expect(
          toHex(out),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
        );
        sha(List.filled(1000000, 0x61));
        expect(
          toHex(out),
          'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
        );
      });

      test('IGE differential vs reference, offsets and in-place', () {
        final r = Random(20261111 + (portable ? 1 : 0));
        const lengths = [16, 32, 48, 160, 1024, 4096, 65536 + 16, 1 << 20];
        for (final len in lengths) {
          final key = rnd(r, 32);
          final iv = rnd(r, 32);
          final pt = rnd(r, len);
          final expCt = refIge(true, key, iv, pt);
          final expPt = refIge(false, key, iv, pt); // decrypt of random data

          // Separate buffers at non-zero offsets inside larger views.
          final inBuf = Uint8List(len + 13);
          inBuf.setRange(5, 5 + len, pt);
          final inView = Uint8List.sublistView(inBuf, 2); // offsetInBytes 2
          final outBuf = Uint8List(len + 21);
          final outView = Uint8List.sublistView(outBuf, 4);
          // Key/iv as views too.
          final keyBuf = Uint8List(40)..setRange(3, 35, key);
          final ivBuf = Uint8List(40)..setRange(7, 39, iv);
          final keyView = Uint8List.sublistView(keyBuf, 3, 35);
          final ivView = Uint8List.sublistView(ivBuf, 7, 39);

          crypto!.aesIge(
            encrypt: true,
            key32: keyView,
            iv32: ivView,
            input: inView,
            inOffset: 3,
            length: len,
            output: outView,
            outOffset: 5,
          );
          expect(
            toHex(Uint8List.sublistView(outView, 5, 5 + len)),
            toHex(expCt),
            reason: 'enc len=$len',
          );
          crypto.aesIge(
            encrypt: false,
            key32: keyView,
            iv32: ivView,
            input: inView,
            inOffset: 3,
            length: len,
            output: outView,
            outOffset: 5,
          );
          expect(
            toHex(Uint8List.sublistView(outView, 5, 5 + len)),
            toHex(expPt),
            reason: 'dec len=$len',
          );
          // Guard bytes untouched.
          expect(outBuf.sublist(0, 9).every((e) => e == 0), isTrue);
          expect(outBuf.sublist(9 + len).every((e) => e == 0), isTrue);

          // In place (same buffer, same absolute offset), round trip.
          final inPlace = Uint8List(len + 7)..setRange(7, 7 + len, pt);
          crypto.aesIge(
            encrypt: true,
            key32: key,
            iv32: iv,
            input: inPlace,
            inOffset: 7,
            length: len,
            output: inPlace,
            outOffset: 7,
          );
          expect(
            toHex(Uint8List.sublistView(inPlace, 7)),
            toHex(expCt),
            reason: 'in-place enc len=$len',
          );
          crypto.aesIge(
            encrypt: false,
            key32: key,
            iv32: iv,
            input: inPlace,
            inOffset: 7,
            length: len,
            output: inPlace,
            outOffset: 7,
          );
          expect(
            toHex(Uint8List.sublistView(inPlace, 7)),
            toHex(pt),
            reason: 'in-place dec len=$len',
          );
        }
      });

      test('CTR differential vs pointycastle, random splits, counter wrap',
          () {
        final r = Random(77 + (portable ? 1 : 0));
        final ivs = <Uint8List>[
          rnd(r, 16),
          Uint8List(16)..fillRange(0, 16, 0xff),
          Uint8List(16)
            ..fillRange(0, 16, 0xff)
            ..[15] = 0xfe,
          Uint8List(16)
            ..fillRange(8, 16, 0xff), // carry into the upper 64 bits
        ];
        for (final iv in ivs) {
          for (final total in [1, 15, 16, 17, 63, 64, 65, 1000, 70000]) {
            final key = rnd(r, 32);
            final data = rnd(r, total);
            final exp = refCtr(key, iv, data);
            final buf = Uint8List(total + 9)..setRange(9, 9 + total, data);
            final ctr = crypto!.createCtr(key, iv);
            var off = 0;
            const pattern = [1, 3, 4, 15, 16, 17, 1000, 4096];
            var p = r.nextInt(pattern.length);
            while (off < total) {
              var n = pattern[p % pattern.length];
              if (r.nextInt(4) == 0) n = r.nextInt(200) + 1;
              p++;
              if (n > total - off) n = total - off;
              ctr.process(buf, 9 + off, n);
              off += n;
            }
            ctr.dispose();
            expect(
              toHex(Uint8List.sublistView(buf, 9)),
              toHex(exp),
              reason: 'iv=${toHex(iv)} total=$total',
            );
          }
        }
      });

      test('SHA-256 differential vs pointycastle with offsets', () {
        final r = Random(99 + (portable ? 1 : 0));
        final out = Uint8List(40);
        for (final len in [
          for (var i = 0; i <= 200; i++) i,
          511,
          512,
          513,
          100000,
          1 << 20,
        ]) {
          final data = rnd(r, len + 11);
          final view = Uint8List.sublistView(data, 4);
          crypto!.sha256(view, 7, len, out, 5);
          final exp = refSha(Uint8List.sublistView(data, 11, 11 + len));
          expect(
            toHex(Uint8List.sublistView(out, 5, 37)),
            toHex(exp),
            reason: 'len=$len',
          );
          // Concat split at a random point.
          final split = len == 0 ? 0 : r.nextInt(len + 1);
          crypto.sha256Concat(
            data,
            11,
            split,
            data,
            11 + split,
            len - split,
            out,
          );
          expect(
            toHex(Uint8List.sublistView(out, 0, 32)),
            toHex(exp),
            reason: 'concat len=$len split=$split',
          );
        }
      });
    });
  }

  test('accelerated and portable produce identical output', () {
    final c = crypto!;
    final r = Random(4242);
    final key = rnd(r, 32);
    final iv = rnd(r, 32);
    final data = rnd(r, 1 << 18);
    Uint8List run(bool portable, bool enc) {
      c.forcePortableForTesting(portable);
      final out = Uint8List(data.length);
      c.aesIge(
        encrypt: enc,
        key32: key,
        iv32: iv,
        input: data,
        inOffset: 0,
        length: data.length,
        output: out,
        outOffset: 0,
      );
      final ctr = c.createCtr(key, Uint8List.sublistView(iv, 0, 16));
      ctr.process(out, 0, out.length);
      ctr.dispose();
      final h = Uint8List(32);
      c.sha256(out, 0, out.length, h);
      c.forcePortableForTesting(false);
      return Uint8List.fromList([...h, ...out.sublist(0, 64)]);
    }

    for (final enc in [true, false]) {
      expect(toHex(run(true, enc)), toHex(run(false, enc)));
    }
  });
}
