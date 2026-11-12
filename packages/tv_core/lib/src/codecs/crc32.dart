import 'dart:typed_data';

final Uint32List _table = _buildTable();

Uint32List _buildTable() {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}

/// CRC-32 (IEEE 802.3, as used by zlib/PNG) of `data[start..end)`.
///
/// Pass the previous result as [crc] to checksum data in several chunks.
/// `crc32("123456789")` is `0xCBF43926`.
int crc32(List<int> data, {int crc = 0, int start = 0, int? end}) {
  final stop = end ?? data.length;
  RangeError.checkValidRange(start, stop, data.length);
  var c = crc ^ 0xFFFFFFFF;
  for (var i = start; i < stop; i++) {
    c = _table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
