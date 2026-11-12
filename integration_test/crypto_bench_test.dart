// On-device crypto benchmark. NO user data: every input is generated here from
// fixed seeds, nothing touches the network, the library, or the session.
//
// Measures MB/s (1 MB = 2^20 bytes, median of timed runs) for the MTProto hot
// paths, for up to four implementations:
//   ref     frozen copy of tg 0.0.20 (packages/tg/tool/reference)
//   lib     whatever packages/tg/lib/src currently is, through TgInternals
//           (the original code until T1.3, the rewritten code after)
//   nPort   tv_crypto native library, portable C path forced
//   nAccel  tv_crypto native library, hardware path (ARMv8 CE / AES-NI);
//           reported only when the library says it is active
// and asserts parity (identical bytes) between all of them on the same inputs.
//
// "encode 512 KiB" and "receive 1 MiB" for the native columns are the crypto
// part of the transport pipeline built from tv_crypto primitives (SHA-256
// msg_key, key derivation, IGE, CTR); TL (de)serialization is not included, as
// T2.2 has not wired native crypto into tg yet. The ref/lib columns run the
// real encoder / receive transformer (including TL), so the native columns are
// an optimistic bound of what T2.2 will deliver.
//
// Run (see tool/perf_baseline.md):
//   tool/measure_device.ps1 -Test crypto_bench
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart';
import 'package:tv_crypto/tv_crypto.dart';

// The frozen reference copy lives outside lib/ (tool/), so it is imported by
// path. It only needs packages that are already in the app's package config.
import '../packages/tg/tool/reference/tg_0_0_20_reference.dart';

const int _mib = 1 << 20;

/// Deterministic pseudo-random bytes (xorshift), same generator as the goldens.
Uint8List _det(int seed, int len) {
  final out = Uint8List(len);
  var x = seed ^ 0x2545F4914F6CDD1D;
  if (x == 0) x = 1;
  for (var i = 0; i < len; i++) {
    x ^= x >>> 12;
    x ^= x << 25;
    x ^= x >>> 27;
    out[i] = ((x * 0x2545F4914F6CDD1D) >>> 56) & 0xFF;
  }
  return out;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _le(int v, int n) {
  final b = Uint8List(n);
  final bd = ByteData.sublistView(b);
  if (n == 8) {
    bd.setUint64(0, v, Endian.little);
  } else {
    bd.setUint32(0, v, Endian.little);
  }
  return b;
}

/// Median MB/s of [body] processing [bytes] per run (after one warm-up run).
double _mbps(
  int bytes,
  void Function() body, {
  int minRuns = 3,
  int maxRuns = 40,
  double minSeconds = 1.0,
}) {
  body();
  final times = <int>[];
  final total = Stopwatch()..start();
  while (times.length < minRuns || total.elapsedMilliseconds < minSeconds * 1000) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    times.add(sw.elapsedMicroseconds);
    if (times.length >= maxRuns) break;
  }
  times.sort();
  final median = times[times.length ~/ 2];
  return bytes / _mib / (median / 1e6);
}

Future<double> _mbpsAsync(int bytes, Future<void> Function() body,
    {int minRuns = 3, double minSeconds = 1.0}) async {
  await body();
  final times = <int>[];
  final total = Stopwatch()..start();
  while (times.length < minRuns || total.elapsedMilliseconds < minSeconds * 1000) {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    times.add(sw.elapsedMicroseconds);
    if (times.length >= 40) break;
  }
  times.sort();
  final median = times[times.length ~/ 2];
  return bytes / _mib / (median / 1e6);
}

/// MTProto 2.0 key derivation with tv_crypto: key/iv for [x] (0 sending, 8
/// receiving) from [authKey] and the 16-byte msg_key at [msgKey]+[mkOff].
void _kdf(TvCrypto n, Uint8List authKey, Uint8List msgKey, int mkOff, int x,
    Uint8List key32, Uint8List iv32, Uint8List a, Uint8List b) {
  n.sha256Concat(msgKey, mkOff, 16, authKey, x, 36, a);
  n.sha256Concat(authKey, 40 + x, 36, msgKey, mkOff, 16, b);
  key32.setRange(0, 8, a, 0);
  key32.setRange(8, 24, b, 8);
  key32.setRange(24, 32, a, 24);
  iv32.setRange(0, 8, b, 0);
  iv32.setRange(8, 24, a, 8);
  iv32.setRange(24, 32, b, 24);
}

class _Rows {
  final Map<String, Map<String, double?>> rows = {};
  final Map<String, bool> parity = {};

  void put(String name, {double? ref, double? lib, double? nPort, double? nAccel}) {
    rows[name] = {'ref': ref, 'lib': lib, 'nativePortable': nPort, 'nativeAccel': nAccel};
    String f(double? v) => v == null ? '      n/a' : v.toStringAsFixed(2).padLeft(9);
    // ignore: avoid_print
    print('TVDIAG: BENCH ${name.padRight(40)} ref ${f(ref)}  lib ${f(lib)}  '
        'nPort ${f(nPort)}  nAccel ${f(nAccel)}  MB/s');
  }

  void check(String name, bool ok) {
    parity[name] = ok;
    // ignore: avoid_print
    print('TVDIAG: PARITY ${name.padRight(40)} ${ok ? 'OK' : 'MISMATCH'}');
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('crypto bench', () async {
    final out = _Rows();
    final native = TvCrypto.tryLoad();
    // ignore: avoid_print
    print('TVDIAG: BENCH device os=${Platform.operatingSystem} '
        'cores=${Platform.numberOfProcessors}');
    if (native == null) {
      // ignore: avoid_print
      print('TVDIAG: BENCH native: unavailable (TvCrypto.tryLoad() == null)');
    } else {
      // ignore: avoid_print
      print('TVDIAG: BENCH native: info=0x${native.info.toRadixString(16)} '
          'aesAccel=${native.aesAccelerated} shaAccel=${native.shaAccelerated}');
    }
    final hasAccel = native != null && (() {
      native.forcePortableForTesting(false);
      return native.aesAccelerated;
    })();

    // Runs [body] with the native library in portable mode, then accelerated.
    // Returns (portable, accel); accel is null when no hardware path is active.
    (double?, double?) both(double Function() body) {
      if (native == null) return (null, null);
      native.forcePortableForTesting(true);
      final p = body();
      double? a;
      if (hasAccel) {
        native.forcePortableForTesting(false);
        a = body();
      }
      native.forcePortableForTesting(false);
      return (p, a);
    }

    final key = _det(1, 32);
    final iv32 = _det(2, 32);
    final iv16 = _det(3, 16);
    final mib = _det(4, _mib);

    // ------------------------------------------------------------- parity
    // IGE on several sizes, all implementations on identical inputs.
    for (final len in <int>[16, 32, 48, 1024, 65536, _mib]) {
      // Fresh offset-0 copies: the original code reads `input.buffer` whole
      // and may work in place, so views or shared buffers would skew parity.
      final input = Uint8List.fromList(mib.sublist(0, len));
      for (final enc in <bool>[true, false]) {
        final expect = refAesIgeEncryptDecrypt(
            Uint8List.fromList(input), RefAesKeyIV(key, iv32), enc);
        final lib = TgInternals.aesIge(Uint8List.fromList(input), key, iv32,
            encrypt: enc);
        out.check('IGE ${enc ? 'enc' : 'dec'} $len lib==ref', _eq(expect, lib));
        if (native != null) {
          for (final portable in <bool>[true, false]) {
            if (!portable && !hasAccel) continue;
            native.forcePortableForTesting(portable);
            final o = Uint8List(len);
            native.aesIge(
                encrypt: enc,
                key32: key,
                iv32: iv32,
                input: input,
                inOffset: 0,
                length: len,
                output: o,
                outOffset: 0);
            out.check('IGE ${enc ? 'enc' : 'dec'} $len ${portable ? 'nPort' : 'nAccel'}==ref',
                _eq(expect, o));
          }
          native.forcePortableForTesting(false);
        }
      }
    }
    // CTR with the odd chunk pattern the transport produces.
    {
      const pattern = [1, 3, 4, 15, 16, 17, 1000, 4096];
      const total = 200000;
      final src = _det(11, total);
      final ref = Uint8List.fromList(src);
      final rc = RefAesCtr(key, iv16);
      var pos = 0, pi = 0;
      while (pos < total) {
        final n = pattern[pi++ % pattern.length].clamp(1, total - pos);
        rc.encryptDecrypt(Uint8List.sublistView(ref, pos, pos + n), n);
        pos += n;
      }
      if (native != null) {
        for (final portable in <bool>[true, false]) {
          if (!portable && !hasAccel) continue;
          native.forcePortableForTesting(portable);
          final got = Uint8List.fromList(src);
          final nc = native.createCtr(key, iv16);
          pos = 0;
          pi = 0;
          while (pos < total) {
            final n = pattern[pi++ % pattern.length].clamp(1, total - pos);
            nc.process(got, pos, n);
            pos += n;
          }
          nc.dispose();
          out.check('CTR chunked ${portable ? 'nPort' : 'nAccel'}==ref', _eq(ref, got));
        }
        native.forcePortableForTesting(false);
      }
    }
    // SHA-256.
    if (native != null) {
      final expect = refSha256(mib);
      for (final portable in <bool>[true, false]) {
        if (!portable && !hasAccel) continue;
        native.forcePortableForTesting(portable);
        final o = Uint8List(32);
        native.sha256(mib, 0, mib.length, o);
        out.check('SHA-256 1MiB ${portable ? 'nPort' : 'nAccel'}==ref', _eq(expect, o));
      }
      native.forcePortableForTesting(false);
    }

    // -------------------------------------------------------------- IGE
    for (final enc in <bool>[true, false]) {
      final refV = _mbps(_mib,
          () => refAesIgeEncryptDecrypt(mib, RefAesKeyIV(key, iv32), enc));
      final libV =
          _mbps(_mib, () => TgInternals.aesIge(mib, key, iv32, encrypt: enc));
      final work = Uint8List(_mib);
      final (p, a) = both(() => _mbps(
          _mib,
          () => native!.aesIge(
              encrypt: enc,
              key32: key,
              iv32: iv32,
              input: mib,
              inOffset: 0,
              length: _mib,
              output: work,
              outOffset: 0),
          maxRuns: 400));
      out.put('AES-IGE ${enc ? 'encrypt' : 'decrypt'} 1 MiB',
          ref: refV, lib: libV, nPort: p, nAccel: a);
      await Future<void>.delayed(Duration.zero);
    }

    // -------------------------------------------------------------- CTR
    {
      final chunk = _det(5, 16384);
      final refV = _mbps(_mib, () {
        final c = RefAesCtr(key, iv16);
        final b = Uint8List.fromList(chunk);
        for (var i = 0; i < _mib ~/ chunk.length; i++) {
          c.encryptDecrypt(b, b.length);
        }
      });
      final libV = _mbps(_mib, () {
        final c = AesCtr(key, iv16);
        final b = Uint8List.fromList(chunk);
        for (var i = 0; i < _mib ~/ chunk.length; i++) {
          c.encryptDecrypt(b, b.length);
        }
      });
      final (p, a) = both(() => _mbps(_mib, () {
            final c = native!.createCtr(key, iv16);
            final b = Uint8List.fromList(chunk);
            for (var i = 0; i < _mib ~/ chunk.length; i++) {
              c.process(b, 0, b.length);
            }
            c.dispose();
          }, maxRuns: 400));
      out.put('AES-CTR 1 MiB (16 KiB chunks)', ref: refV, lib: libV, nPort: p, nAccel: a);
      await Future<void>.delayed(Duration.zero);
    }

    // ----------------------------------------------------------- SHA-256
    {
      final refV = _mbps(_mib, () => refSha256(mib));
      final o = Uint8List(32);
      final (p, a) = both(() =>
          _mbps(_mib, () => native!.sha256(mib, 0, mib.length, o), maxRuns: 400));
      out.put('SHA-256 1 MiB', ref: refV, nPort: p, nAccel: a);
      await Future<void>.delayed(Duration.zero);
    }

    // ------------------------------------------- encode a 512 KiB part
    {
      final part = t.UploadSaveFilePart(
          fileId: 123456789, filePart: 3, bytes: _det(6, 512 * 1024));
      final authKey = _det(8, 256);
      const authId = 0x1122334455667788;
      const salt = 0x0102030405060708;
      final msgBuf = <int>[];
      part.serialize(msgBuf);
      final msgLen = msgBuf.length;
      // Explicit padding that makes the IGE input a multiple of 16 (>= 12).
      final padLen = 16 + (16 - msgLen % 16) % 16;
      final padding = _det(7, padLen);
      final tgAuth = AuthorizationKey(authId, authKey, salt);
      final refAuth = RefAuthKey(authId, authKey, salt);
      const msgId = 0x5000000000000004;
      final refV = _mbps(
          512 * 1024,
          () => refEncodeWithAuthPadded(
              part, const RefIdSeq(msgId, 9), 0x77, refAuth, padding),
          minRuns: 3);
      final libV = _mbps(
          512 * 1024,
          () => TgInternals.encodeWithAuth(part,
              msgId: msgId,
              seqno: 9,
              sessionId: 0x77,
              auth: tgAuth,
              padding: padding),
          minRuns: 3);

      // Reference frame -> decrypted body, to drive the native pipeline.
      final frame = TgInternals.encodeWithAuth(part,
          msgId: msgId, seqno: 9, sessionId: 0x77, auth: tgAuth, padding: padding);
      final encLen = 32 + msgLen + padLen;
      final prefix = frame.length - (8 + 16 + encLen);
      var nativeV = <double?>[null, null];
      if (native != null && (prefix == 0 || prefix == 4)) {
        final msgKeyOff = prefix + 8;
        final cipherOff = prefix + 24;
        final k32 = Uint8List(32), i32 = Uint8List(32);
        final a = Uint8List(32), b = Uint8List(32), h = Uint8List(32);
        final body = Uint8List(encLen);
        // Decrypt the reference ciphertext natively (sending keys, x = 0).
        _kdf(native, authKey, frame, msgKeyOff, 0, k32, i32, a, b);
        native.aesIge(
            encrypt: false,
            key32: k32,
            iv32: i32,
            input: frame,
            inOffset: cipherOff,
            length: encLen,
            output: body,
            outOffset: 0);
        // msg_key = sha256(authKey[88:120] || body)[8:24]
        native.sha256Concat(authKey, 88, 32, body, 0, encLen, h);
        out.check('encode msg_key native==frame', _eq(h.sublist(8, 24), frame.sublist(msgKeyOff, msgKeyOff + 16)));
        final work = Uint8List(encLen);
        final cipher = Uint8List(encLen);
        void encodeNative() {
          work.setRange(0, encLen, body); // building the clear text
          native.sha256Concat(authKey, 88, 32, work, 0, encLen, h);
          _kdf(native, authKey, h, 8, 0, k32, i32, a, b);
          native.aesIge(
              encrypt: true,
              key32: k32,
              iv32: i32,
              input: work,
              inOffset: 0,
              length: encLen,
              output: cipher,
              outOffset: 0);
        }

        for (final portable in <bool>[true, false]) {
          if (!portable && !hasAccel) continue;
          native.forcePortableForTesting(portable);
          encodeNative();
          out.check('encode cipher ${portable ? 'nPort' : 'nAccel'}==frame',
              _eq(cipher, frame.sublist(cipherOff, cipherOff + encLen)));
        }
        native.forcePortableForTesting(false);
        final (p, ac) = both(() => _mbps(512 * 1024, encodeNative, maxRuns: 400));
        nativeV = [p, ac];
      } else if (native != null) {
        out.check('encode frame layout understood (prefix=$prefix)', false);
      }
      out.put('encode 512 KiB UploadSaveFilePart',
          ref: refV, lib: libV, nPort: nativeV[0], nAccel: nativeV[1]);
      await Future<void>.delayed(Duration.zero);
    }

    // ------------------------------------- receive a 1 MiB UploadFile frame
    {
      final authKey = _det(8, 256);
      const authId = 0x1122334455667788;
      const salt = 0x0102030405060708;
      final tgAuth = AuthorizationKey(authId, authKey, salt);
      final random58 = _det(9, 58);
      final reply = t.RpcResult(
        reqMsgId: 0x1234,
        result: t.UploadFile(
            type: const t.StorageFileJpeg(), mtime: 1700000000, bytes: mib),
      );
      final bodyBuf = <int>[];
      reply.serialize(bodyBuf);
      final head = BytesBuilder()
        ..add(_le(0x1111, 8))
        ..add(_le(0x2222, 8))
        ..add(_le(0x3000000000000001, 8))
        ..add(_le(1, 4))
        ..add(_le(bodyBuf.length, 4))
        ..add(bodyBuf);
      var padLen = 16;
      padLen += (16 - ((32 + bodyBuf.length + padLen) % 16)) % 16;
      head.add(_det(10, padLen));
      final plain = head.toBytes();
      final msgKey = Uint8List.fromList(
          refSha256([...authKey.sublist(96, 128), ...plain]).sublist(8, 24));
      final cipher = TgInternals.encryptDecryptMessage(Uint8List.fromList(plain),
          encrypt: true, x: 8, authKey: authKey, msgKey: msgKey, msgKeyOffset: 0);
      final cipherBytes = Uint8List.fromList(cipher);
      final bodyBytes = BytesBuilder()
        ..add(_le(authId, 8))
        ..add(msgKey)
        ..add(cipherBytes);
      final bb = bodyBytes.toBytes();
      final wire = BytesBuilder()
        ..add(_le(bb.length, 4))
        ..add(bb);
      final wireBytes = wire.toBytes();
      final obf = Uint8List.fromList(wireBytes);
      Obfuscation.preamble(random58, false, 2).recv.encryptDecrypt(obf, obf.length);
      final chunks = <Uint8List>[
        for (var p = 0; p < obf.length; p += 65536)
          Uint8List.sublistView(obf, p, (p + 65536).clamp(0, obf.length)),
      ];

      Future<void> receive(Stream<t.TlObject> Function(Stream<List<int>> raw) attach) async {
        final got = Completer<t.TlObject>();
        attach(Stream<List<int>>.fromIterable(chunks)).listen((m) {
          if (!got.isCompleted) got.complete(m);
        });
        final m = await got.future;
        if (m is! t.RpcResult) throw StateError('unexpected ${m.runtimeType}');
      }

      final refV = await _mbpsAsync(
          _mib,
          () => receive((raw) => RefEncryptedTransformer(
                  raw,
                  RefObfuscation.preamble(random58, false, 2),
                  authKey,
                  <int>{})
              .stream));
      final libV = await _mbpsAsync(
          _mib,
          () => receive((raw) => TgInternals.encryptedReceiver(
              raw, Obfuscation.preamble(random58, false, 2), tgAuth, <int>{})));

      var nativeV = <double?>[null, null];
      if (native != null) {
        // Native pipeline with its own CTR key (the preamble's key is not
        // exposed): obfuscate the same wire with RefAesCtr, undo with native.
        final wireObf = Uint8List.fromList(wireBytes);
        RefAesCtr(key, iv16).encryptDecrypt(wireObf, wireObf.length);
        final buf = Uint8List(wireObf.length);
        final planeOut = Uint8List(cipherBytes.length);
        final k32 = Uint8List(32), i32 = Uint8List(32);
        final a = Uint8List(32), b = Uint8List(32), h = Uint8List(32);
        var verified = true;
        void receiveNative() {
          buf.setRange(0, buf.length, wireObf);
          final c = native.createCtr(key, iv16);
          for (var p = 0; p < buf.length; p += 65536) {
            c.process(buf, p, (buf.length - p).clamp(0, 65536));
          }
          c.dispose();
          // frame = len(4) | authKeyId(8) | msgKey(16) | cipher
          _kdf(native, authKey, buf, 12, 8, k32, i32, a, b);
          native.aesIge(
              encrypt: false,
              key32: k32,
              iv32: i32,
              input: buf,
              inOffset: 28,
              length: planeOut.length,
              output: planeOut,
              outOffset: 0);
          native.sha256Concat(authKey, 96, 32, planeOut, 0, planeOut.length, h);
          for (var i = 0; i < 16; i++) {
            if (h[8 + i] != buf[12 + i]) verified = false;
          }
        }

        for (final portable in <bool>[true, false]) {
          if (!portable && !hasAccel) continue;
          native.forcePortableForTesting(portable);
          verified = true;
          receiveNative();
          out.check('receive pipeline ${portable ? 'nPort' : 'nAccel'}: ctr==wire',
              _eq(buf, wireBytes));
          out.check('receive pipeline ${portable ? 'nPort' : 'nAccel'}: plain+msg_key',
              verified && _eq(planeOut, plain));
        }
        native.forcePortableForTesting(false);
        final (p, ac) = both(() => _mbps(_mib, receiveNative, maxRuns: 400));
        nativeV = [p, ac];
      }
      out.put('receive 1 MiB UploadFile frame',
          ref: refV, lib: libV, nPort: nativeV[0], nAccel: nativeV[1]);
    }

    if (native != null) native.forcePortableForTesting(false);

    binding.reportData = <String, dynamic>{
      'testName': 'crypto_bench',
      'os': Platform.operatingSystem,
      'cores': Platform.numberOfProcessors,
      'nativeLoaded': native != null,
      'nativeInfo': native?.info,
      'nativeAesAccelActive': native?.aesAccelerated,
      'nativeShaAccelActive': native?.shaAccelerated,
      'rows': out.rows,
      'parity': out.parity,
    };

    final bad = out.parity.entries.where((e) => !e.value).map((e) => e.key).toList();
    expect(bad, isEmpty, reason: 'parity mismatches: $bad');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
