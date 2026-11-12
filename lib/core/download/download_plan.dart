import 'package:tg/tg.dart' show TgCrypto;

/// Pure, network-free planning for downloads.
///
/// Telegram's upload.getFile requires an [offset] that is a multiple of 4 KB
/// and a [limit] that divides 1 MB. We always request fixed windows; the server
/// returns fewer bytes for the final window, which the caller detects.
class DownloadLimits {
  /// Window used with the native (hardware AES) crypto backend: the maximum
  /// getFile allows. Decrypting 1 MB natively takes about a millisecond.
  static const int nativeChunkSize = 1024 * 1024;

  /// Window used with the pure-Dart fallback: each response frame is decrypted
  /// synchronously on the isolate that owns the connection, so smaller frames
  /// keep any single decrypt short and don't stall the thumbnails sharing it.
  static const int dartChunkSize = 128 * 1024;

  /// Bytes requested per getFile call, chosen from the crypto backend active
  /// on the calling isolate (each isolate resolves its own backend).
  static int get chunkSize => TgCrypto.backend.name == 'native'
      ? nativeChunkSize
      : dartChunkSize;
}

/// A single getFile request window.
class DownloadRange {
  final int offset;
  final int limit;

  const DownloadRange({required this.offset, required this.limit});

  @override
  bool operator ==(Object other) =>
      other is DownloadRange && other.offset == offset && other.limit == limit;

  @override
  int get hashCode => Object.hash(offset, limit);

  @override
  String toString() => 'DownloadRange(offset: $offset, limit: $limit)';
}

/// Produces the ordered getFile windows needed to read a document of [size]
/// bytes. Offsets are [chunkSize]-aligned (and therefore 4 KB-aligned).
List<DownloadRange> downloadRanges(
  int size, {
  int? chunkSize,
}) {
  chunkSize ??= DownloadLimits.chunkSize;
  if (size < 0) {
    throw ArgumentError.value(size, 'size', 'must be non-negative');
  }
  final ranges = <DownloadRange>[];
  for (var offset = 0; offset < size; offset += chunkSize) {
    ranges.add(DownloadRange(offset: offset, limit: chunkSize));
  }
  return ranges;
}
