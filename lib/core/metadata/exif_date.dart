import 'dart:typed_data';

import '../../models/capture_date.dart' show plausibleCaptureMs;

/// EXIF tags read for the capture time, in order of preference.
const int _tagDateTimeOriginal = 0x9003;
const int _tagDateTimeDigitized = 0x9004;
const int _tagDateTime = 0x0132;
const int _tagExifIfd = 0x8769;

/// Most entries an IFD may declare before it is treated as garbage.
const int _maxIfdEntries = 1000;

/// True when [bytes] starts like a JPEG (SOI marker).
bool looksLikeJpegHeader(Uint8List bytes) =>
    bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// The capture time in the EXIF block of the JPEG whose first bytes are
/// [bytes] (a truncated header is fine: only what is there is read), as epoch
/// milliseconds: DateTimeOriginal, else DateTimeDigitized, else DateTime.
///
/// EXIF carries no time zone, so the wall-clock time is read in the device's
/// local zone, the same rule as the dates in file names. Values that are not
/// a real calendar time or not plausible (see [plausibleCaptureMs]) are
/// skipped. Null when the bytes are not a JPEG, have no EXIF block within
/// them, or no usable date. Never throws on malformed input. [now] is for
/// tests.
int? jpegExifCaptureMs(Uint8List bytes, {DateTime? now}) {
  try {
    final tiff = _exifTiff(bytes);
    if (tiff == null) return null;
    return _tiffCaptureMs(tiff, now);
  } catch (_) {
    return null;
  }
}

/// The TIFF payload of the first `Exif\0\0` APP1 segment, cut to the bytes
/// actually present; null when there is none before the image data.
ByteData? _exifTiff(Uint8List b) {
  if (!looksLikeJpegHeader(b)) return null;
  var i = 2;
  while (i + 4 <= b.length) {
    if (b[i] != 0xFF) return null;
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    // Start of scan / end of image: no metadata after this point.
    if (marker == 0xDA || marker == 0xD9) return null;
    // Markers without a length field.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final length = (b[i + 2] << 8) | b[i + 3];
    if (length < 2) return null;
    final start = i + 4;
    if (marker == 0xE1 &&
        start + 6 <= b.length &&
        b[start] == 0x45 && // E
        b[start + 1] == 0x78 && // x
        b[start + 2] == 0x69 && // i
        b[start + 3] == 0x66 && // f
        b[start + 4] == 0 &&
        b[start + 5] == 0) {
      final tiffStart = start + 6;
      final end = (i + 2 + length).clamp(tiffStart, b.length);
      return ByteData.sublistView(b, tiffStart, end);
    }
    i += 2 + length;
  }
  return null;
}

int? _tiffCaptureMs(ByteData t, DateTime? now) {
  if (t.lengthInBytes < 8) return null;
  final Endian endian;
  if (t.getUint8(0) == 0x49 && t.getUint8(1) == 0x49) {
    endian = Endian.little;
  } else if (t.getUint8(0) == 0x4D && t.getUint8(1) == 0x4D) {
    endian = Endian.big;
  } else {
    return null;
  }
  if (t.getUint16(2, endian) != 42) return null;

  final ifd0 = _readIfd(t, t.getUint32(4, endian), endian);
  final exifPointer = ifd0[_tagExifIfd];
  final exif = exifPointer == null
      ? const <int, _Entry>{}
      : _readIfd(t, _entryValueU32(t, exifPointer, endian), endian);

  for (final entry in [
    exif[_tagDateTimeOriginal],
    exif[_tagDateTimeDigitized],
    ifd0[_tagDateTime],
  ]) {
    if (entry == null) continue;
    final ms = _parseExifDate(_entryAscii(t, entry, endian), now);
    if (ms != null) return ms;
  }
  return null;
}

/// One IFD entry: its type, count and the offset of its 4-byte value field.
class _Entry {
  const _Entry(this.type, this.count, this.valueAt);
  final int type;
  final int count;
  final int valueAt;
}

/// The entries of the IFD at [offset] that fit in [t]; empty when the IFD is
/// out of range or malformed.
Map<int, _Entry> _readIfd(ByteData t, int offset, Endian endian) {
  final out = <int, _Entry>{};
  if (offset < 8 || offset + 2 > t.lengthInBytes) return out;
  final count = t.getUint16(offset, endian);
  if (count > _maxIfdEntries) return out;
  for (var k = 0; k < count; k++) {
    final at = offset + 2 + k * 12;
    if (at + 12 > t.lengthInBytes) break;
    final tag = t.getUint16(at, endian);
    out.putIfAbsent(
      tag,
      () => _Entry(t.getUint16(at + 2, endian), t.getUint32(at + 4, endian), at + 8),
    );
  }
  return out;
}

/// LONG (4) or SHORT (3) value of a pointer entry; 0 when unusable.
int _entryValueU32(ByteData t, _Entry e, Endian endian) {
  if (e.type == 4 || e.type == 13) return t.getUint32(e.valueAt, endian);
  if (e.type == 3) return t.getUint16(e.valueAt, endian);
  return 0;
}

/// The ASCII value of [e] (up to its first NUL), or null when it is not
/// ASCII or does not fit in [t].
String? _entryAscii(ByteData t, _Entry e, Endian endian) {
  if (e.type != 2 || e.count < 1 || e.count > 64) return null;
  final start = e.count <= 4 ? e.valueAt : t.getUint32(e.valueAt, endian);
  if (start < 0 || start + e.count > t.lengthInBytes) return null;
  final codes = <int>[];
  for (var k = 0; k < e.count; k++) {
    final c = t.getUint8(start + k);
    if (c == 0) break;
    codes.add(c);
  }
  return String.fromCharCodes(codes);
}

final RegExp _exifDate = RegExp(r'^\s*(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})');

/// `YYYY:MM:DD HH:MM:SS` as local wall-clock time, epoch ms; null when it is
/// blank/zero, not a real calendar time, or not plausible.
int? _parseExifDate(String? s, DateTime? now) {
  if (s == null) return null;
  final m = _exifDate.firstMatch(s);
  if (m == null) return null;
  final v = [for (var g = 1; g <= 6; g++) int.parse(m.group(g)!)];
  final (y, mo, d, h, mi, sec) = (v[0], v[1], v[2], v[3], v[4], v[5]);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 59) {
    return null;
  }
  final t = DateTime(y, mo, d, h, mi, sec);
  // DateTime rolls Feb 30 over into March: reject instead.
  if (t.year != y || t.month != mo || t.day != d) return null;
  return plausibleCaptureMs(t.millisecondsSinceEpoch, now: now);
}
