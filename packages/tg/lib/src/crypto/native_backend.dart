import 'dart:typed_data';

import 'package:tv_crypto/tv_crypto.dart';

import 'backend.dart';
import 'dart_backend.dart';

/// TeleVault (T2.2): backend over the native `tv_crypto` library (AES-NI /
/// ARMv8 Crypto Extensions with a portable C fallback). Zero copy: views at
/// any offset (aligned or not) are passed to native code as-is; in-place IGE
/// (same buffer and offset) is supported.
class NativeCryptoBackend implements TgCryptoBackend {
  NativeCryptoBackend(this._tv);

  /// The native backend, or `null` when `tv_crypto` cannot be loaded.
  /// Never throws.
  static NativeCryptoBackend? tryCreate() {
    try {
      final tv = TvCrypto.tryLoad();
      return tv == null ? null : NativeCryptoBackend(tv);
    } catch (_) {
      return null;
    }
  }

  final TvCrypto _tv;

  /// `tv_crypto` info bits ([TvCryptoInfo]).
  int get info => _tv.info;

  @override
  String get name => 'native';

  @override
  void aesIge({
    required bool encrypt,
    required Uint8List key32,
    required Uint8List iv32,
    required Uint8List input,
    required int inOffset,
    required int length,
    required Uint8List output,
    required int outOffset,
  }) =>
      _tv.aesIge(
        encrypt: encrypt,
        key32: key32,
        iv32: iv32,
        input: input,
        inOffset: inOffset,
        length: length,
        output: output,
        outOffset: outOffset,
      );

  @override
  TgCtrStream createCtr(Uint8List key32, Uint8List iv16) =>
      _NativeCtrStream(_tv.createCtr(key32, iv16));

  @override
  void sha256(Uint8List data, int offset, int length, Uint8List out32,
          int outOffset) =>
      _tv.sha256(data, offset, length, out32, outOffset);
}

class _NativeCtrStream implements TgCtrStream {
  _NativeCtrStream(this._ctr);

  final TvCtr _ctr;

  @override
  void process(Uint8List data, int offset, int length) =>
      _ctr.process(data, offset, length);

  @override
  void dispose() => _ctr.dispose();
}

/// Compares [candidate] with [DartCryptoBackend] on fixed vectors: IGE
/// encrypt and decrypt (unaligned view, then in place), CTR with a
/// byte-granular split, SHA-256 at an offset. Returns `false` on any
/// mismatch or error; never throws.
bool crossCheckBackend(TgCryptoBackend candidate) {
  try {
    final ref = DartCryptoBackend();
    final key = _pattern(32, 7);
    final iv32 = _pattern(32, 101);
    final iv16 = _pattern(16, 203);
    // 80 bytes of data at offset 3 of a larger buffer (unaligned view).
    final plain = _pattern(80, 29);
    final big = Uint8List(80 + 3 + 5)..setRange(3, 83, plain);
    final view = Uint8List.sublistView(big, 3, 83);

    // IGE encrypt: view -> fresh buffer at offset 4.
    final encRef = Uint8List(80);
    ref.aesIge(
        encrypt: true,
        key32: key,
        iv32: iv32,
        input: plain,
        inOffset: 0,
        length: 80,
        output: encRef,
        outOffset: 0);
    final encOut = Uint8List(84);
    candidate.aesIge(
        encrypt: true,
        key32: key,
        iv32: iv32,
        input: view,
        inOffset: 0,
        length: 80,
        output: encOut,
        outOffset: 4);
    if (!_eq(encRef, 0, encOut, 4, 80)) return false;

    // IGE decrypt in place (same buffer and offset) back to the plaintext.
    final dec = Uint8List(84)..setRange(4, 84, encRef);
    candidate.aesIge(
        encrypt: false,
        key32: key,
        iv32: iv32,
        input: dec,
        inOffset: 4,
        length: 80,
        output: dec,
        outOffset: 4);
    if (!_eq(plain, 0, dec, 4, 80)) return false;

    // CTR: 5 + 50 + 25 bytes against one 80-byte Dart pass.
    final ctrRef = Uint8List.fromList(plain);
    final r = ref.createCtr(key, iv16);
    try {
      r.process(ctrRef, 0, 80);
    } finally {
      r.dispose();
    }
    final ctrOut = Uint8List.fromList(big);
    final c = candidate.createCtr(key, iv16);
    try {
      c.process(ctrOut, 3, 5);
      c.process(ctrOut, 8, 50);
      c.process(ctrOut, 58, 25);
    } finally {
      c.dispose();
    }
    if (!_eq(ctrRef, 0, ctrOut, 3, 80)) return false;

    // SHA-256 of 77 bytes at offset 3, written at offset 4.
    final shaRef = Uint8List(32);
    ref.sha256(big, 3, 77, shaRef, 0);
    final shaOut = Uint8List(36);
    candidate.sha256(big, 3, 77, shaOut, 4);
    if (!_eq(shaRef, 0, shaOut, 4, 32)) return false;
    return true;
  } catch (_) {
    return false;
  }
}

/// Backend selection (T2.2): native only if [enabled], [loadNative] returns
/// a backend, and [crossCheckBackend] passes; otherwise [DartCryptoBackend].
/// Emits exactly one `TVDIAG: tg crypto backend=<name>/<info>` line through
/// [log]. `<info>` is the `tv_crypto` info bits as hex when the library
/// loaded, `off` when disabled by `TV_NATIVE_CRYPTO=false`, `none` when it
/// could not be loaded. Never throws.
TgCryptoBackend selectCryptoBackend({
  required bool enabled,
  required NativeCryptoBackend? Function() loadNative,
  required void Function(String line) log,
}) {
  TgCryptoBackend chosen = DartCryptoBackend();
  var info = 'off';
  try {
    if (enabled) {
      info = 'none';
      final native = loadNative();
      if (native != null) {
        info = '0x${native.info.toRadixString(16).padLeft(2, '0')}';
        if (crossCheckBackend(native)) chosen = native;
      }
    }
  } catch (_) {
    chosen = DartCryptoBackend();
  }
  try {
    log('TVDIAG: tg crypto backend=${chosen.name}/$info');
  } catch (_) {}
  return chosen;
}

Uint8List _pattern(int n, int seed) {
  final b = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    b[i] = x >> 16;
  }
  return b;
}

bool _eq(Uint8List a, int ao, Uint8List b, int bo, int n) {
  for (var i = 0; i < n; i++) {
    if (a[ao + i] != b[bo + i]) return false;
  }
  return true;
}
