/// Pure, network-free planning for downloads.
///
/// Telegram's upload.getFile requires an [offset] that is a multiple of 4 KB
/// and a [limit] that divides 1 MB. We always request 1 MB windows; the server
/// returns fewer bytes for the final window, which the caller detects.
class DownloadLimits {
  /// Bytes requested per getFile call. 1 MB is the max and divides cleanly into
  /// the required 4 KB alignment.
  static const int chunkSize = 1024 * 1024;
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
  int chunkSize = DownloadLimits.chunkSize,
}) {
  if (size < 0) {
    throw ArgumentError.value(size, 'size', 'must be non-negative');
  }
  final ranges = <DownloadRange>[];
  for (var offset = 0; offset < size; offset += chunkSize) {
    ranges.add(DownloadRange(offset: offset, limit: chunkSize));
  }
  return ranges;
}
