import 'dart:typed_data';

import 'dart_backend.dart';
import 'native_backend.dart';

/// Crypto primitives needed by the MTProto transport. The default backend is
/// chosen at first use ([TgCrypto.backend]): native `tv_crypto`
/// ([NativeCryptoBackend]) when it loads and passes a cross-check, else pure
/// Dart ([DartCryptoBackend]).
abstract class TgCryptoBackend {
  String get name;

  /// AES-256-IGE as in Telegram: `iv32 = [c_prev(16) | p_prev(16)]`.
  /// `length % 16 == 0`. `input == output` (same buffer and offset) is allowed.
  void aesIge({
    required bool encrypt,
    required Uint8List key32,
    required Uint8List iv32,
    required Uint8List input,
    required int inOffset,
    required int length,
    required Uint8List output,
    required int outOffset,
  });

  /// AES-256-CTR stream, 128-bit big-endian counter, byte-granular keystream.
  TgCtrStream createCtr(Uint8List key32, Uint8List iv16);

  /// SHA-256 of `data[offset .. offset+length)` into `out32[outOffset ..+32)`.
  void sha256(
      Uint8List data, int offset, int length, Uint8List out32, int outOffset);
}

abstract class TgCtrStream {
  /// XORs the next `length` keystream bytes into `data[offset .. offset+length)`.
  void process(Uint8List data, int offset, int length);
  void dispose();
}

/// Holder of the active backend.
class TgCrypto {
  TgCrypto._();

  /// Compile-time switch: `--dart-define=TV_NATIVE_CRYPTO=false` forces the
  /// pure-Dart backend.
  static const bool nativeEnabled =
      bool.fromEnvironment('TV_NATIVE_CRYPTO', defaultValue: true);

  static TgCryptoBackend? _resolved;
  static TgCryptoBackend? _override;

  /// The active backend. Resolved lazily once per isolate (statics are
  /// per isolate) by [selectCryptoBackend]: native when enabled, loadable and
  /// equal to the Dart backend on fixed vectors, else pure Dart. Never throws.
  static TgCryptoBackend get backend => _override ?? (_resolved ??= _resolve());

  /// Installs [b] for this isolate (tests, benchmarks).
  static set backend(TgCryptoBackend b) => _override = b;

  /// Drops an installed backend; the next read returns the default resolved
  /// backend (resolved and logged at most once per isolate).
  static void resetForTesting() {
    _override = null;
  }

  static TgCryptoBackend _resolve() {
    try {
      return selectCryptoBackend(
        enabled: nativeEnabled,
        loadNative: NativeCryptoBackend.tryCreate,
        log: print,
      );
    } catch (_) {
      return DartCryptoBackend();
    }
  }
}
