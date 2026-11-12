import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

/// SHA-256 of `data[offset .. offset+length)` written to `out32[outOffset ..
/// outOffset+32)`. Hashes a view of [data] (no copy of the input).
void dartSha256(
    Uint8List data, int offset, int length, Uint8List out32, int outOffset) {
  RangeError.checkValidRange(offset, offset + length, data.length);
  RangeError.checkValidRange(outOffset, outOffset + 32, out32.length);
  final digest =
      c.sha256.convert(Uint8List.sublistView(data, offset, offset + length));
  out32.setRange(outOffset, outOffset + 32, digest.bytes);
}
