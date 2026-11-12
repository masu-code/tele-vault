// Allocation-free replacement for t's BinaryReader (which copies with
// skip().take().toList() on every read). Drop-in: it only overrides the
// primitive reads; vectors, strings, bools and readObject() are inherited from
// the base class and route through these overrides.
//
// Differences from the base class, all deliberate:
//  - reading past the end throws RangeError (the base silently truncated
//    readRawBytes/readBytes and threw on the next read);
//  - views are supported (offsets are relative to the start of the view).
import 'dart:typed_data';

import 'package:t/t.dart' as t;

class FastBinaryReader extends t.BinaryReader {
  FastBinaryReader(Uint8List buffer)
      : _data = ByteData.sublistView(buffer),
        _length = buffer.length,
        super(buffer);

  final ByteData _data;
  final int _length;
  int _pos = 0;

  /// Bytes left to read.
  int get remaining => _length - _pos;

  @override
  int get position => _pos;

  Endian _endian(bool bigEndian) => bigEndian ? Endian.big : Endian.little;

  @override
  int readInt16([bool bigEndian = false]) {
    final x = _data.getUint16(_pos, _endian(bigEndian));
    _pos += 2;
    return x;
  }

  @override
  int readInt32([bool bigEndian = false]) {
    final x = _data.getUint32(_pos, _endian(bigEndian));
    _pos += 4;
    return x;
  }

  @override
  int readInt64([bool bigEndian = false]) {
    final x = _data.getUint64(_pos, _endian(bigEndian));
    _pos += 8;
    return x;
  }

  @override
  t.Int128 readInt128() => t.Int128(_copy(16));

  @override
  t.Int256 readInt256() => t.Int256(_copy(32));

  @override
  double readFloat64() {
    final x = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return x;
  }

  @override
  Uint8List readBytes() {
    // TL bytes: 1 length byte (< 254) or 0xFE + 3 length bytes (LE), then the
    // payload, then zero padding up to a multiple of 4 for the whole item.
    final first = buffer[_pos++];
    final int length;
    final int header;
    if (first < 254) {
      length = first;
      header = 1;
    } else {
      length = readInt16() + (buffer[_pos++] << 16);
      header = 4;
    }

    final out = _copy(length);

    // Padding may be missing at the very end of a buffer; do not throw for it.
    _pos += (4 - (header + length) % 4) % 4;
    return out;
  }

  @override
  Uint8List readRawBytes(int length) => _copy(length);

  /// Copy of the next [length] bytes; advances the position.
  Uint8List _copy(int length) {
    final start = _pos;
    final end = start + length;
    if (length < 0 || end > _length) {
      throw RangeError('Cannot read $length bytes at $start of $_length');
    }
    _pos = end;
    return buffer.sublist(start, end);
  }
}
