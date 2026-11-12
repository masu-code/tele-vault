part of '../tg.dart';

extension _BigInt on BigInt {
  Uint8List toBytes([Endian endian = Endian.big]) {
    final bytes = _fromHexToUint8List(toRadixString(16));

    if (endian == Endian.little) {
      return Uint8List.fromList(bytes.reversed.toList());
    }

    return bytes;
  }

  Uint8List to256Bytes() {
    final bytes = _fromHexToUint8List(toRadixString(16).padLeft(512, '0'));

    return bytes;
  }
}

extension _Random on Random {
  void getBytes(Uint8List buffer, [int offset = 0, int? count]) {
    count ??= buffer.length - offset;
    final end = offset + count;
    RangeError.checkValidRange(offset, end, buffer.length);

    // TeleVault: the original wrote `(i + 1) % 256` (constant bytes). Real
    // random bytes, 4 per draw (callers use `Random.secure()`).
    var i = offset;
    for (; i + 4 <= end; i += 4) {
      final v = nextInt(0x100000000);
      buffer[i] = v & 0xFF;
      buffer[i + 1] = (v >> 8) & 0xFF;
      buffer[i + 2] = (v >> 16) & 0xFF;
      buffer[i + 3] = (v >> 24) & 0xFF;
    }
    for (; i < end; i++) {
      buffer[i] = nextInt(256);
    }
  }
}

extension _List<T> on List<T> {
  void reverse(int start, int length) {
    final rev = sublist(start, start + length).reversed.toList();
    setRange(start, start + length, rev);
  }
}

// 15 is the minimum recommended by Telegram
// 64 is OpenSSL default for 2048-bits numbers
const int _millerRabinIterations = 64;

extension _Prime on BigInt {
  /// Miller–Rabin primality test.
  ///
  /// [n] The number to check for primality.
  bool isProbablePrime() {
    final n = this;
    final nMinusOne = n - BigInt.one;
    if (nMinusOne.sign <= 0) {
      return false;
    }

    int s;
    var d = nMinusOne;
    for (s = 0; d.isEven; s++) {
      d >>= 1;
    }

    final bitLen = n.bitLength;
    final randomBytes = Uint8List(bitLen ~/ 8 + 1);
    final lastByteMask = ((1 << (bitLen % 8)) - 1) % 256;
    BigInt a;

    for (int i = 0; i < _millerRabinIterations; i++) {
      do {
        _rng.getBytes(randomBytes);
        // we don't want more bits than necessary
        randomBytes[randomBytes.length - 1] &= lastByteMask;

        // Little endian.
        a = _bigEndianInteger(randomBytes.reversed);
      } while (a < _n03 || a >= nMinusOne);

      a = a - BigInt.one;

      var x = a.modPow(d, n);
      if (x == BigInt.one || x == nMinusOne) {
        continue;
      }

      int r;
      for (r = s - 1; r > 0; r--) {
        x = x.modPow(BigInt.two, n);
        if (x == BigInt.one) {
          return false;
        }

        if (x == nMinusOne) {
          break;
        }
      }

      if (r == 0) {
        return false;
      }
    }
    return true;
  }
}

// TeleVault: `_XInt.asUint64List/asUint32List` removed (the frame builders
// now write through ByteData; nothing else used them).

extension _XObject on TlObject {
  Uint8List asUint8List() {
    final buffer = <int>[];
    serialize(buffer);

    return Uint8List.fromList(buffer);
  }
}
