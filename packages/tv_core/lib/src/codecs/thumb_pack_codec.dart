import 'dart:convert';
import 'dart:typed_data';

import 'crc32.dart';
import 'preview_codec.dart';

/// Thrown for a thumb pack that cannot be encoded (limits/validation) or whose
/// container (header, TOC) cannot be trusted. Per-entry damage is NOT thrown:
/// see [ThumbPackDecoded.corruptIds].
class ThumbPackFormatException implements Exception {
  const ThumbPackFormatException(this.message);
  final String message;
  @override
  String toString() => 'ThumbPackFormatException: $message';
}

/// One thumbnail to put in / read from a pack.
class ThumbPackEntry {
  const ThumbPackEntry({
    required this.id,
    required this.jpeg,
    required this.width,
    required this.height,
    this.preview,
  });

  /// `FileItem.id` the thumbnail belongs to.
  final String id;
  final Uint8List jpeg;
  final int width;
  final int height;

  /// Optional `th1:<base64>` preview of this thumbnail.
  final String? preview;
}

/// A TOC row: where an entry's JPEG lives, without the bytes.
class ThumbPackTocEntry {
  const ThumbPackTocEntry({
    required this.id,
    required this.offset,
    required this.length,
    required this.width,
    required this.height,
    required this.crc,
    this.preview,
  });
  final String id;

  /// Relative to [ThumbPackToc.dataOffset].
  final int offset;
  final int length;
  final int width;
  final int height;
  final int crc;
  final String? preview;
}

/// Parsed header + TOC of a pack (enough to range-read single thumbnails).
class ThumbPackToc {
  const ThumbPackToc({
    required this.packId,
    required this.createdAt,
    required this.entries,
    required this.corruptIds,
    required this.malformedEntries,
    required this.dataOffset,
  });
  final String packId;
  final DateTime createdAt;

  /// Structurally valid rows, in file order.
  final List<ThumbPackTocEntry> entries;

  /// Ids of rows that failed validation (bad numbers, overlap, ...).
  final List<String> corruptIds;

  /// Rows without a usable id, or repeated ids; cannot be reported by id.
  final int malformedEntries;

  /// Absolute byte offset of the data section (16 + tocLen).
  final int dataOffset;
}

class ThumbPackDecoded {
  const ThumbPackDecoded({
    required this.packId,
    required this.createdAt,
    required this.entries,
    required this.corruptIds,
    required this.malformedEntries,
  });
  final String packId;
  final DateTime createdAt;

  /// Entries whose blob passed every check.
  final List<ThumbPackEntry> entries;

  /// Ids whose entry or blob failed validation (never thrown).
  final List<String> corruptIds;
  final int malformedEntries;
}

/// TVTP v1 thumbnail pack (one Telegram document, up to 512 thumbnails).
///
/// Layout: 16-byte LE header (`TVTP`, u16 version, u16 flags, u32 tocLen,
/// u32 tocCrc32), UTF-8 JSON TOC, then the concatenated JPEGs.
abstract final class ThumbPackCodec {
  static const int version = 1;
  static const int headerLength = 16;
  static const String formatName = 'televault-thumbpack';
  static const int maxEntries = 512;
  static const int maxBlobBytes = 200 * 1024;
  static const int maxDataBytes = 8 * 1024 * 1024;
  static const int maxTocBytes = 512 * 1024;
  static const int _maxDim = 65535;

  /// Caption of the Telegram message that carries a pack.
  static String captionFor(String packId) => 'TELEVAULT_THUMBS_V1 $packId';
  static String fileNameFor(String packId) => 'televault_thumbs_$packId.tvtp';

  static Uint8List encode({
    required String packId,
    required DateTime createdAt,
    required List<ThumbPackEntry> entries,
  }) {
    if (packId.isEmpty) {
      throw const ThumbPackFormatException('empty pack id');
    }
    if (entries.length > maxEntries) {
      throw ThumbPackFormatException('${entries.length} entries > $maxEntries');
    }
    final seen = <String>{};
    var dataLen = 0;
    final toc = <Map<String, Object?>>[];
    for (final e in entries) {
      if (e.id.isEmpty) {
        throw const ThumbPackFormatException('empty entry id');
      }
      if (!seen.add(e.id)) {
        throw const ThumbPackFormatException('duplicate entry id');
      }
      if (!_isJpeg(e.jpeg)) {
        throw const ThumbPackFormatException('entry is not a JPEG (SOI/EOI)');
      }
      if (e.jpeg.length > maxBlobBytes) {
        throw ThumbPackFormatException(
            'entry of ${e.jpeg.length} B > $maxBlobBytes');
      }
      if (e.width < 1 ||
          e.width > _maxDim ||
          e.height < 1 ||
          e.height > _maxDim) {
        throw const ThumbPackFormatException('entry has invalid dimensions');
      }
      final p = e.preview;
      if (p != null && PreviewCodec.fromWire(p) == null) {
        throw const ThumbPackFormatException('entry has an invalid preview');
      }
      final row = <String, Object?>{
        'id': e.id,
        'off': dataLen,
        'len': e.jpeg.length,
        'w': e.width,
        'h': e.height,
        'crc': crc32(e.jpeg),
      };
      if (p != null) row['p'] = p;
      toc.add(row);
      dataLen += e.jpeg.length;
    }
    if (dataLen > maxDataBytes) {
      throw ThumbPackFormatException('data of $dataLen B > $maxDataBytes');
    }
    final tocBytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'format': formatName,
      'v': version,
      'pack_id': packId,
      'created_at': createdAt.toUtc().toIso8601String(),
      'entries': toc,
    })));
    if (tocBytes.length > maxTocBytes) {
      throw ThumbPackFormatException('TOC of ${tocBytes.length} B too large');
    }

    final out = Uint8List(headerLength + tocBytes.length + dataLen);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 4, const [0x54, 0x56, 0x54, 0x50]); // "TVTP"
    bd.setUint16(4, version, Endian.little);
    bd.setUint16(6, 0, Endian.little);
    bd.setUint32(8, tocBytes.length, Endian.little);
    bd.setUint32(12, crc32(tocBytes), Endian.little);
    out.setRange(headerLength, headerLength + tocBytes.length, tocBytes);
    var pos = headerLength + tocBytes.length;
    for (final e in entries) {
      out.setRange(pos, pos + e.jpeg.length, e.jpeg);
      pos += e.jpeg.length;
    }
    return out;
  }

  /// Parses and validates the header and TOC. [bytes] only needs to contain
  /// the first `16 + tocLen` bytes (so a ranged download is enough).
  /// Throws [ThumbPackFormatException] on bad magic, version != 1, truncated
  /// or oversized TOC, TOC CRC mismatch or an invalid TOC document.
  static ThumbPackToc readToc(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw const ThumbPackFormatException('shorter than the header');
    }
    if (bytes[0] != 0x54 ||
        bytes[1] != 0x56 ||
        bytes[2] != 0x54 ||
        bytes[3] != 0x50) {
      throw const ThumbPackFormatException('bad magic');
    }
    final bd = ByteData.sublistView(bytes);
    final ver = bd.getUint16(4, Endian.little);
    if (ver != version) {
      throw ThumbPackFormatException('unsupported version $ver');
    }
    final tocLen = bd.getUint32(8, Endian.little);
    final tocCrc = bd.getUint32(12, Endian.little);
    if (tocLen > maxTocBytes) {
      throw ThumbPackFormatException('TOC of $tocLen B too large');
    }
    if (bytes.length < headerLength + tocLen) {
      throw const ThumbPackFormatException('truncated TOC');
    }
    final tocBytes =
        Uint8List.sublistView(bytes, headerLength, headerLength + tocLen);
    if (crc32(tocBytes) != tocCrc) {
      throw const ThumbPackFormatException('TOC CRC mismatch');
    }

    final Object? doc;
    try {
      doc = jsonDecode(utf8.decode(tocBytes));
    } catch (_) {
      throw const ThumbPackFormatException('TOC is not valid UTF-8 JSON');
    }
    if (doc is! Map) {
      throw const ThumbPackFormatException('TOC is not an object');
    }
    if (doc['format'] != formatName) {
      throw const ThumbPackFormatException('wrong TOC format name');
    }
    final v = doc['v'];
    if (v is! int || v != version) {
      throw ThumbPackFormatException('unsupported TOC version $v');
    }
    final packId = doc['pack_id'];
    if (packId is! String || packId.isEmpty) {
      throw const ThumbPackFormatException('missing pack_id');
    }
    final created = doc['created_at'];
    final createdAt = created is String ? DateTime.tryParse(created) : null;
    if (createdAt == null) {
      throw const ThumbPackFormatException('missing or invalid created_at');
    }
    final rawEntries = doc['entries'];
    if (rawEntries is! List) {
      throw const ThumbPackFormatException('entries is not a list');
    }
    if (rawEntries.length > maxEntries) {
      throw ThumbPackFormatException(
          '${rawEntries.length} entries > $maxEntries');
    }

    final entries = <ThumbPackTocEntry>[];
    final corrupt = <String>[];
    final ids = <String>{};
    var malformed = 0;
    var prevEnd = 0;
    for (final raw in rawEntries) {
      if (raw is! Map) {
        malformed++;
        continue;
      }
      final id = raw['id'];
      if (id is! String || id.isEmpty || !ids.add(id)) {
        malformed++; // unusable id, or a repeated one (ambiguous)
        continue;
      }
      final off = raw['off'];
      final len = raw['len'];
      final w = raw['w'];
      final h = raw['h'];
      final crc = raw['crc'];
      final p = raw['p'];
      if (off is! int ||
          len is! int ||
          w is! int ||
          h is! int ||
          crc is! int ||
          off < 0 ||
          len <= 0 ||
          len > maxBlobBytes ||
          w < 1 ||
          w > _maxDim ||
          h < 1 ||
          h > _maxDim ||
          crc < 0 ||
          crc > 0xFFFFFFFF ||
          off < prevEnd ||
          off + len > maxDataBytes) {
        corrupt.add(id);
        continue;
      }
      prevEnd = off + len;
      entries.add(ThumbPackTocEntry(
        id: id,
        offset: off,
        length: len,
        width: w,
        height: h,
        crc: crc,
        preview: p is String && PreviewCodec.fromWire(p) != null ? p : null,
      ));
    }
    return ThumbPackToc(
      packId: packId,
      createdAt: createdAt.toUtc(),
      entries: entries,
      corruptIds: corrupt,
      malformedEntries: malformed,
      dataOffset: headerLength + tocLen,
    );
  }

  /// Decodes a whole pack. Container problems throw; a damaged entry is
  /// listed in [ThumbPackDecoded.corruptIds] and the rest is still returned.
  static ThumbPackDecoded decode(Uint8List bytes) {
    final toc = readToc(bytes);
    final dataLen = bytes.length - toc.dataOffset;
    if (dataLen > maxDataBytes) {
      throw ThumbPackFormatException('data of $dataLen B > $maxDataBytes');
    }
    final entries = <ThumbPackEntry>[];
    final corrupt = List<String>.of(toc.corruptIds);
    for (final e in toc.entries) {
      if (e.offset + e.length > dataLen) {
        corrupt.add(e.id);
        continue;
      }
      final start = toc.dataOffset + e.offset;
      final blob = Uint8List.sublistView(bytes, start, start + e.length);
      if (!_isJpeg(blob) || crc32(blob) != e.crc) {
        corrupt.add(e.id);
        continue;
      }
      entries.add(ThumbPackEntry(
        id: e.id,
        jpeg: Uint8List.fromList(blob),
        width: e.width,
        height: e.height,
        preview: e.preview,
      ));
    }
    return ThumbPackDecoded(
      packId: toc.packId,
      createdAt: toc.createdAt,
      entries: entries,
      corruptIds: corrupt,
      malformedEntries: toc.malformedEntries,
    );
  }

  static bool _isJpeg(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0xFF &&
      b[1] == 0xD8 &&
      b[b.length - 2] == 0xFF &&
      b[b.length - 1] == 0xD9;
}
