import 'dart:typed_data';

import 'aes256.dart';
import 'aes_ctr.dart';
import 'aes_ige.dart';
import 'backend.dart';
import 'sha256.dart';

/// Pure-Dart backend: T-table AES-256 with one key schedule per call/stream.
class DartCryptoBackend implements TgCryptoBackend {
  @override
  String get name => 'dart';

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
  }) {
    final aes = Aes256(key32);
    try {
      aesIgeProcess(
        aes: aes,
        encrypt: encrypt,
        iv32: iv32,
        input: input,
        inOffset: inOffset,
        length: length,
        output: output,
        outOffset: outOffset,
      );
    } finally {
      aes.wipe();
    }
  }

  @override
  TgCtrStream createCtr(Uint8List key32, Uint8List iv16) =>
      DartCtrStream(key32, iv16);

  @override
  void sha256(Uint8List data, int offset, int length, Uint8List out32,
          int outOffset) =>
      dartSha256(data, offset, length, out32, outOffset);
}
