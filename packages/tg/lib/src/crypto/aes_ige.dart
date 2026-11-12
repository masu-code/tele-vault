import 'dart:typed_data';

import 'aes256.dart';

/// AES-256-IGE (Telegram flavour).
///
/// `iv32 = [c_prev(16) | p_prev(16)]`.
///   encrypt: `C = E(P xor c_prev) xor p_prev`
///   decrypt: `P = D(C xor p_prev) xor c_prev`
/// then `c_prev = C; p_prev = P`.
///
/// [input] and [output] may be the same buffer at the same offset (in place);
/// partially overlapping ranges are handled by copying. Offsets that are not
/// 4-byte aligned inside their buffer take a copying slow path, so views at
/// any offset are supported. Nothing is allocated per block.
void aesIgeProcess({
  required Aes256 aes,
  required bool encrypt,
  required Uint8List iv32,
  required Uint8List input,
  required int inOffset,
  required int length,
  required Uint8List output,
  required int outOffset,
}) {
  if (length < 0 || length % 16 != 0) {
    throw ArgumentError.value(length, 'length', 'must be a multiple of 16');
  }
  if (iv32.length != 32) {
    throw ArgumentError.value(iv32.length, 'iv32.length', 'must be 32');
  }
  RangeError.checkValidRange(inOffset, inOffset + length, input.length);
  RangeError.checkValidRange(outOffset, outOffset + length, output.length);
  if (length == 0) return;

  final inAbs = input.offsetInBytes + inOffset;
  final outAbs = output.offsetInBytes + outOffset;
  // `buffer` returns a fresh wrapper each call: compare with `==`, not identical().
  final sameBuffer = input.buffer == output.buffer;
  final inPlace = sameBuffer && inAbs == outAbs;
  final partialOverlap = sameBuffer &&
      !inPlace &&
      inAbs < outAbs + length &&
      outAbs < inAbs + length;

  if ((inAbs & 3) != 0 || (outAbs & 3) != 0 || partialOverlap) {
    // Slow path: aligned scratch copies of the input and output.
    final tmpIn = Uint8List(length)..setRange(0, length, input, inOffset);
    final tmpOut = Uint8List(length);
    _igeWords(aes, encrypt, iv32, tmpIn.buffer.asUint32List(),
        tmpOut.buffer.asUint32List(), length ~/ 4);
    output.setRange(outOffset, outOffset + length, tmpOut);
    return;
  }

  final wi = input.buffer.asUint32List(inAbs, length ~/ 4);
  final wo = inPlace ? wi : output.buffer.asUint32List(outAbs, length ~/ 4);
  _igeWords(aes, encrypt, iv32, wi, wo, length ~/ 4);
}

void _igeWords(Aes256 aes, bool encrypt, Uint8List iv32, Uint32List wi,
    Uint32List wo, int words) {
  final iv = Uint8List.fromList(iv32).buffer.asUint32List();
  var a0 = iv[0], a1 = iv[1], a2 = iv[2], a3 = iv[3]; // c_prev
  var b0 = iv[4], b1 = iv[5], b2 = iv[6], b3 = iv[7]; // p_prev
  if (encrypt) {
    for (var i = 0; i < words; i += 4) {
      final p0 = wi[i], p1 = wi[i + 1], p2 = wi[i + 2], p3 = wi[i + 3];
      wo[i] = p0 ^ a0;
      wo[i + 1] = p1 ^ a1;
      wo[i + 2] = p2 ^ a2;
      wo[i + 3] = p3 ^ a3;
      aes.encryptBlock(wo, i, wo, i);
      a0 = wo[i] ^ b0;
      a1 = wo[i + 1] ^ b1;
      a2 = wo[i + 2] ^ b2;
      a3 = wo[i + 3] ^ b3;
      wo[i] = a0;
      wo[i + 1] = a1;
      wo[i + 2] = a2;
      wo[i + 3] = a3;
      b0 = p0;
      b1 = p1;
      b2 = p2;
      b3 = p3;
    }
  } else {
    for (var i = 0; i < words; i += 4) {
      final c0 = wi[i], c1 = wi[i + 1], c2 = wi[i + 2], c3 = wi[i + 3];
      wo[i] = c0 ^ b0;
      wo[i + 1] = c1 ^ b1;
      wo[i + 2] = c2 ^ b2;
      wo[i + 3] = c3 ^ b3;
      aes.decryptBlock(wo, i, wo, i);
      b0 = wo[i] ^ a0;
      b1 = wo[i + 1] ^ a1;
      b2 = wo[i + 2] ^ a2;
      b3 = wo[i + 3] ^ a3;
      wo[i] = b0;
      wo[i + 1] = b1;
      wo[i + 2] = b2;
      wo[i + 3] = b3;
      a0 = c0;
      a1 = c1;
      a2 = c2;
      a3 = c3;
    }
  }
}
