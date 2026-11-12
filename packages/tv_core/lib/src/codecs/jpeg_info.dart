import 'dart:typed_data';

/// Reads a JPEG's pixel dimensions from its SOF header, or null if [bytes]
/// isn't a JPEG this can parse. Never throws, whatever the input.
///
/// Same scan as the app's original `_jpegSize` (upload_service.dart), but every
/// access is bounds-checked and the scan stops at the first marker that cannot
/// precede a SOF (SOS/EOI) instead of walking into entropy-coded data.
({int w, int h})? jpegSize(Uint8List bytes) {
  final n = bytes.length;
  if (n < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < n) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    // SOF0..SOF15, minus DHT (C4), JPG (C8) and DAC (CC), which share the range.
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      final h = (bytes[i + 5] << 8) | bytes[i + 6];
      final w = (bytes[i + 7] << 8) | bytes[i + 8];
      return (w: w, h: h);
    }
    // Markers without a length field: TEM (01), RSTn (D0..D7), SOI (D8).
    if (marker == 0x00 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    // EOI or SOS before any SOF: not a parseable header.
    if (marker == 0xD9 || marker == 0xDA) return null;
    final len = (bytes[i + 2] << 8) | bytes[i + 3];
    if (len < 2) return null;
    i += 2 + len;
  }
  return null;
}
