// AOT benchmark of the tg transport hot paths: the frozen reference copy
// (tool/reference) versus the code under lib/src (through TgInternals), which
// since T1.3 is the new path (TgCrypto.backend, ByteSink, RecvBuffer,
// FastBinaryReader). T2.2: the "new" paths are measured under both backends,
// pure Dart and native tv_crypto (when it loads).
//
// tv_crypto ships its library through a build hook, so compile with
// `dart build cli`, which bundles the code assets next to the exe:
//   dart build cli -t tool/bench.dart -o "$env:TEMP\tg_bench"
//   & "$env:TEMP\tg_bench\bundle\bin\bench.exe"
//
// Prints MB/s (1 MB = 2^20 bytes, median of the timed runs). No user data.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:t/t.dart' as t;
import 'package:tg/src/crypto/dart_backend.dart';
import 'package:tg/src/crypto/native_backend.dart';
import 'package:tg/tg.dart';

import 'gen_goldens.dart' show applyChunking, detBytes, serializeObject;
import 'reference/tg_0_0_20_reference.dart';

const int _mib = 1 << 20;

/// Runs [body] until at least [minRuns] runs and [minSeconds] elapsed
/// (after one warm-up run); returns the median MB/s for [bytes] per run.
double _mbps(int bytes, void Function() body,
    {int minRuns = 3, double minSeconds = 1.5}) {
  body(); // warm-up
  final times = <int>[];
  final total = Stopwatch()..start();
  while (times.length < minRuns || total.elapsedMilliseconds < minSeconds * 1000) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    times.add(sw.elapsedMicroseconds);
    if (times.length >= 40) break;
  }
  times.sort();
  final median = times[times.length ~/ 2];
  return bytes / _mib / (median / 1e6);
}

Future<double> _mbpsAsync(int bytes, Future<void> Function() body,
    {int minRuns = 3, double minSeconds = 1.5}) async {
  await body(); // warm-up
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

String _f(double? v) => v == null ? '      n/a' : v.toStringAsFixed(2).padLeft(9);

void _row(String name, double ref, double dart, double? native) {
  stdout.writeln('${name.padRight(44)} ref ${_f(ref)}   dart ${_f(dart)}'
      '   native ${_f(native)} MB/s');
}

/// Runs [body] once per backend (Dart, then native if it loads).
Future<(double, double?)> _both(
    NativeCryptoBackend? native, FutureOr<double> Function() body) async {
  TgCrypto.backend = DartCryptoBackend();
  final d = await body();
  double? n;
  if (native != null) {
    TgCrypto.backend = native;
    n = await body();
  }
  TgCrypto.resetForTesting();
  return (d, n);
}

Uint8List _copy(Uint8List b) => Uint8List.fromList(b);

Future<void> main() async {
  final native = NativeCryptoBackend.tryCreate();
  stdout.writeln('tg 0.0.20 transport bench (AOT), '
      '${Platform.operatingSystem} ${Platform.numberOfProcessors} cores, '
      'default backend ${TgCrypto.backend.name}, native info '
      '${native == null ? 'n/a' : '0x${native.info.toRadixString(16)}'}');

  final key = detBytes(1, 32);
  final iv32 = detBytes(2, 32);
  final iv16 = detBytes(3, 16);
  final mib = detBytes(4, _mib);

  // --- IGE 1 MiB ---
  final igeRefEnc = _mbps(_mib,
      () => refAesIgeEncryptDecrypt(mib, RefAesKeyIV(key, iv32), true));
  final (igeEncD, igeEncN) = await _both(native, () => _mbps(
      _mib, () => TgInternals.aesIge(mib, key, iv32, encrypt: true)));
  _row('AES-IGE encrypt 1 MiB', igeRefEnc, igeEncD, igeEncN);
  final igeRefDec = _mbps(_mib,
      () => refAesIgeEncryptDecrypt(mib, RefAesKeyIV(key, iv32), false));
  final (igeDecD, igeDecN) = await _both(native, () => _mbps(
      _mib, () => TgInternals.aesIge(mib, key, iv32, encrypt: false)));
  _row('AES-IGE decrypt 1 MiB', igeRefDec, igeDecD, igeDecN);

  // --- CTR: 1 MiB in 16 KiB chunks (call sites pass len == input.length) ---
  final chunk = detBytes(5, 16384);
  final ctrRef = _mbps(_mib, () {
    final c = RefAesCtr(key, iv16);
    final b = _copy(chunk);
    for (var i = 0; i < _mib ~/ chunk.length; i++) {
      c.encryptDecrypt(b, b.length);
    }
  });
  final (ctrD, ctrN) = await _both(native, () => _mbps(_mib, () {
        final c = AesCtr(key, iv16);
        final b = _copy(chunk);
        for (var i = 0; i < _mib ~/ chunk.length; i++) {
          c.encryptDecrypt(b, b.length);
        }
      }));
  _row('AES-CTR 1 MiB (16 KiB chunks)', ctrRef, ctrD, ctrN);

  // --- SHA-256 of 1 MiB (pointycastle, via the original helper) ---
  final shaRef = _mbps(_mib, () => refSha256(mib));
  final shaOut = Uint8List(32);
  final (shaD, shaN) = await _both(native, () => _mbps(
      _mib, () => TgCrypto.backend.sha256(mib, 0, mib.length, shaOut, 0)));
  _row('SHA-256 1 MiB', shaRef, shaD, shaN);

  // --- encode a 512 KiB saveFilePart ---
  final part = t.UploadSaveFilePart(
      fileId: 123456789, filePart: 3, bytes: detBytes(6, 512 * 1024));
  // Valid MTProto padding: 32 + len + pad must be a multiple of 16 (the new
  // IGE rejects other lengths; the original silently accepted them).
  final partLen = serializeObject(part).length;
  final padding = detBytes(7, ((0x7FFFFFF0 - (partLen + 32)) % 16) + 64);
  final authKey = detBytes(8, 256);
  const authId = 0x1122334455667788;
  const salt = 0x0102030405060708;
  final tgAuth = AuthorizationKey(authId, authKey, salt);
  final refAuth = RefAuthKey(authId, authKey, salt);
  final encRef = _mbps(
      512 * 1024,
      () => refEncodeWithAuthPadded(
          part, const RefIdSeq(0x5000000000000004, 9), 0x77, refAuth, padding));
  final (encD, encN) = await _both(
      native,
      () => _mbps(
          512 * 1024,
          () => TgInternals.encodeWithAuth(part,
              msgId: 0x5000000000000004,
              seqno: 9,
              sessionId: 0x77,
              auth: tgAuth,
              padding: padding)));
  _row('encode 512 KiB UploadSaveFilePart (no CTR)', encRef, encD, encN);

  // --- receive of a 1 MiB UploadFile frame (CTR + frame split + IGE + TL) ---
  final random58 = detBytes(9, 58);
  final reply = t.RpcResult(
    reqMsgId: 0x1234,
    result: t.UploadFile(
        type: const t.StorageFileJpeg(), mtime: 1700000000, bytes: mib),
  );
  final bodyBuf = <int>[];
  reply.serialize(bodyBuf);
  final head = BytesBuilder()
    ..add(_le(0x1111, 8)) // salt
    ..add(_le(0x2222, 8)) // session
    ..add(_le(0x3000000000000001, 8)) // msg id
    ..add(_le(1, 4)) // seqno
    ..add(_le(bodyBuf.length, 4))
    ..add(bodyBuf);
  var padLen = 16;
  padLen += (16 - ((32 + bodyBuf.length + padLen) % 16)) % 16;
  head.add(detBytes(10, padLen));
  final plain = head.toBytes();
  final sha = _msgKeyOf(authKey, plain);
  final cipher = TgInternals.encryptDecryptMessage(plain,
      encrypt: true, x: 8, authKey: authKey, msgKey: sha, msgKeyOffset: 0);
  final body = BytesBuilder()
    ..add(_le(authId, 8))
    ..add(sha)
    ..add(cipher);
  final bodyBytes = body.toBytes();
  final wire = BytesBuilder()
    ..add(_le(bodyBytes.length, 4))
    ..add(bodyBytes);
  final wireBytes = wire.toBytes();
  Obfuscation.preamble(random58, false, 2).recv.encryptDecrypt(wireBytes, wireBytes.length);
  final chunks = applyChunking(wireBytes, {'kind': 'fixed', 'size': 65536});

  Future<void> receive(
      Stream<t.TlObject> Function(Stream<List<int>> raw) attach) async {
    final got = Completer<t.TlObject>();
    attach(Stream<List<int>>.fromIterable(chunks)).listen((m) {
      if (!got.isCompleted) got.complete(m);
    });
    final m = await got.future;
    if (m is! t.RpcResult) throw StateError('unexpected ${m.runtimeType}');
  }

  final rxRef = await _mbpsAsync(
      _mib,
      () => receive((raw) => RefEncryptedTransformer(
              raw,
              RefObfuscation.preamble(random58, false, 2),
              authKey,
              <int>{})
          .stream),
      minRuns: 3);
  final (rxD, rxN) = await _both(
      native,
      () => _mbpsAsync(
          _mib,
          () => receive((raw) => TgInternals.encryptedReceiver(
              raw, Obfuscation.preamble(random58, false, 2), tgAuth, <int>{})),
          minRuns: 3));
  _row('receive 1 MiB UploadFile frame (64 KiB chunks)', rxRef, rxD, rxN);
}

Uint8List _msgKeyOf(List<int> authKey, Uint8List plain) {
  final h = refSha256([...authKey.sublist(96, 128), ...plain]);
  return Uint8List.fromList(h.sublist(8, 24));
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
