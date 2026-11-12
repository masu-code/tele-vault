/// Native AES-256-IGE, AES-256-CTR and SHA-256 for TeleVault (MTProto).
///
/// Load with [TvCrypto.tryLoad]; it returns `null` when the native library
/// is missing, has an unexpected version, or failed its portable self-test.
/// Accelerated code paths (ARMv8 Crypto Extensions, AES-NI) are chosen at
/// runtime by the library and verified against the portable code at init.
///
/// Buffers are passed to native code without copying
/// (`Uint8List.address` of a view). All arguments are range-checked in Dart
/// before the call.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/bindings.dart' as b;

/// Bits returned by [TvCrypto.info].
abstract final class TvCryptoInfo {
  /// The CPU has AES instructions the library can use.
  static const int aesAccelAvailable = 0x01;

  /// AES instructions are in use (available, self-test ok, not forced off).
  static const int aesAccelActive = 0x02;

  /// The CPU has SHA-256 instructions the library can use.
  static const int shaAccelAvailable = 0x04;

  /// SHA-256 instructions are in use.
  static const int shaAccelActive = 0x08;

  /// Some self-test failed (an accelerated path was disabled, or see
  /// [portableFailed]).
  static const int selfTestFailed = 0x10;

  /// The portable implementation failed its known-answer tests. The library
  /// must not be used; [TvCrypto.tryLoad] returns `null` in that case.
  static const int portableFailed = 0x20;
}

/// Entry point to the native crypto library. One instance per isolate.
final class TvCrypto {
  TvCrypto._();

  /// Native API version this binding was written for.
  static const int expectedVersion = 0x00010000;

  static bool _tried = false;
  static TvCrypto? _instance;

  /// Loads the native library and runs its one-time self-test. Returns
  /// `null` on any failure (never throws). The result is cached per isolate.
  static TvCrypto? tryLoad() {
    if (_tried) return _instance;
    _tried = true;
    try {
      if (b.tvcVersion() != expectedVersion) return null;
      final info = b.tvcInfo();
      if (info & TvCryptoInfo.portableFailed != 0) return null;
      _instance = TvCrypto._();
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }

  /// Current [TvCryptoInfo] bits (the "active" bits reflect
  /// [forcePortableForTesting]).
  int get info => b.tvcInfo();

  bool get aesAccelerated => info & TvCryptoInfo.aesAccelActive != 0;
  bool get shaAccelerated => info & TvCryptoInfo.shaAccelActive != 0;

  /// TESTS ONLY. Process-wide (all isolates): forces the portable code paths.
  void forcePortableForTesting(bool on) => b.tvcForcePortable(on ? 1 : 0);

  /// AES-256-IGE as used by MTProto. [iv32] = c_prev(16) || p_prev(16).
  /// [length] must be a multiple of 16. In-place operation is allowed when
  /// input and output are the same bytes (same buffer and absolute offset);
  /// any other overlap is rejected.
  void aesIge({
    required bool encrypt,
    required Uint8List key32,
    required Uint8List iv32,
    required Uint8List input,
    required int inOffset,
    required int length,
    required Uint8List output,
    required int outOffset,
  }) {
    _checkLen(key32, 32, 'key32');
    _checkLen(iv32, 32, 'iv32');
    if (length % 16 != 0) {
      throw ArgumentError.value(length, 'length', 'must be a multiple of 16');
    }
    RangeError.checkValidRange(inOffset, inOffset + length, input.length);
    RangeError.checkValidRange(outOffset, outOffset + length, output.length);
    _checkOverlap(input, inOffset, output, outOffset, length);
    if (length == 0) return;
    final rc = b.tvcAes256Ige(
      encrypt ? 1 : 0,
      key32.address,
      iv32.address,
      Uint8List.sublistView(input, inOffset, inOffset + length).address,
      Uint8List.sublistView(output, outOffset, outOffset + length).address,
      length,
    );
    if (rc != 0) {
      throw StateError('tvc_aes256_ige failed ($rc)');
    }
  }

  /// Creates an AES-256-CTR keystream (128-bit big-endian counter starting
  /// at [iv16]). Call [TvCtr.dispose] when done; a finalizer frees it
  /// otherwise.
  TvCtr createCtr(Uint8List key32, Uint8List iv16) {
    _checkLen(key32, 32, 'key32');
    _checkLen(iv16, 16, 'iv16');
    return TvCtr._(key32, iv16);
  }

  /// SHA-256 of `data[offset, offset+length)` written to
  /// `out32[outOffset, outOffset+32)`.
  void sha256(
    Uint8List data,
    int offset,
    int length,
    Uint8List out32, [
    int outOffset = 0,
  ]) {
    RangeError.checkValidRange(offset, offset + length, data.length);
    RangeError.checkValidRange(outOffset, outOffset + 32, out32.length);
    b.tvcSha256(
      Uint8List.sublistView(data, offset, offset + length).address,
      length,
      Uint8List.sublistView(out32, outOffset, outOffset + 32).address,
    );
  }

  /// SHA-256 of the concatenation `a || b` (no intermediate copy).
  void sha256Concat(
    Uint8List a,
    int aOffset,
    int aLength,
    Uint8List b2,
    int bOffset,
    int bLength,
    Uint8List out32, [
    int outOffset = 0,
  ]) {
    RangeError.checkValidRange(aOffset, aOffset + aLength, a.length);
    RangeError.checkValidRange(bOffset, bOffset + bLength, b2.length);
    RangeError.checkValidRange(outOffset, outOffset + 32, out32.length);
    b.tvcSha256Two(
      Uint8List.sublistView(a, aOffset, aOffset + aLength).address,
      aLength,
      Uint8List.sublistView(b2, bOffset, bOffset + bLength).address,
      bLength,
      Uint8List.sublistView(out32, outOffset, outOffset + 32).address,
    );
  }

  static void _checkLen(Uint8List v, int len, String name) {
    if (v.length != len) {
      throw ArgumentError.value(v.length, name, 'length must be $len');
    }
  }

  static void _checkOverlap(
    Uint8List input,
    int inOffset,
    Uint8List output,
    int outOffset,
    int length,
  ) {
    if (length == 0 || input.buffer != output.buffer) return;
    final a = input.offsetInBytes + inOffset;
    final c = output.offsetInBytes + outOffset;
    if (a == c) return;
    if (a < c + length && c < a + length) {
      throw ArgumentError('input and output overlap without being identical');
    }
  }
}

/// AES-256-CTR keystream with byte-granular continuation across calls.
/// Not shareable across isolates.
final class TvCtr implements Finalizable {
  TvCtr._(Uint8List key32, Uint8List iv16) : _size = b.tvcAes256CtrCtxSize() {
    final ctx = calloc<Uint8>(_size);
    final rc = b.tvcAes256CtrInit(ctx.cast(), key32.address, iv16.address);
    if (rc != 0) {
      calloc.free(ctx);
      throw StateError('tvc_aes256_ctr_init failed ($rc)');
    }
    _ctx = ctx;
    _finalizer.attach(this, ctx.cast(), detach: this, externalSize: _size);
  }

  static final NativeFinalizer _finalizer = NativeFinalizer(calloc.nativeFree);

  final int _size;
  Pointer<Uint8> _ctx = nullptr;

  bool get isDisposed => _ctx == nullptr;

  /// XORs the keystream into `data[offset, offset+length)` in place.
  void process(Uint8List data, int offset, int length) {
    if (_ctx == nullptr) throw StateError('TvCtr used after dispose');
    RangeError.checkValidRange(offset, offset + length, data.length);
    if (length == 0) return;
    final view = Uint8List.sublistView(data, offset, offset + length);
    b.tvcAes256CtrXor(_ctx.cast(), view.address, view.address, length);
  }

  /// Wipes and frees the native context. Idempotent.
  void dispose() {
    final ctx = _ctx;
    if (ctx == nullptr) return;
    _ctx = nullptr;
    _finalizer.detach(this);
    ctx.asTypedList(_size).fillRange(0, _size, 0);
    calloc.free(ctx);
  }
}
