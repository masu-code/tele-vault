/// Pure, network-free planning of how a local file maps onto Telegram.
///
/// Two levels of splitting are involved:
///  1. SEGMENTS — a logical file is split into segments no larger than
///     [maxSegmentSize]. Each segment becomes ONE Telegram document/message
///     (one [FilePart] in the index). This is what lets a >2GB file live in
///     Telegram, which caps a single file at 2GB (free) / 4GB (premium).
///  2. CHUNKS — within a segment, bytes are uploaded in [chunkSize] pieces via
///     upload.save(Big)FilePart. Telegram requires a fixed part size that
///     divides 512 KB and at most 4000 parts per file.
class UploadLimits {
  /// MTProto upload part size. 512 KB is the maximum and the conventional value.
  static const int chunkSize = 512 * 1024;

  /// Max bytes per segment (one Telegram document). Kept under the 2GB free
  /// ceiling for safety margin.
  static const int maxSegmentSize = 1900 * 1024 * 1024;

  /// Files at or above this size must use the big-file upload path.
  static const int bigFileThreshold = 10 * 1024 * 1024;

  /// Telegram's hard cap on parts per uploaded file.
  static const int maxPartsPerFile = 4000;
}

/// One contiguous slice of the source file that becomes a single Telegram
/// document.
class UploadSegment {
  final int index;
  final int offset;
  final int size;

  const UploadSegment({
    required this.index,
    required this.offset,
    required this.size,
  });

  /// Number of [chunkSize] upload parts this segment needs.
  int chunkCount({int chunkSize = UploadLimits.chunkSize}) =>
      size == 0 ? 1 : (size + chunkSize - 1) ~/ chunkSize;

  /// Whether this segment must go through the big-file upload path.
  bool get isBig => size >= UploadLimits.bigFileThreshold;

  @override
  bool operator ==(Object other) =>
      other is UploadSegment &&
      other.index == index &&
      other.offset == offset &&
      other.size == size;

  @override
  int get hashCode => Object.hash(index, offset, size);

  @override
  String toString() => 'UploadSegment(#$index, offset: $offset, size: $size)';
}

/// Splits a file of [totalSize] bytes into ordered segments.
///
/// A file at or below [maxSegmentSize] yields a single segment, so the common
/// case carries no overhead. Throws [ArgumentError] for a negative size.
List<UploadSegment> planSegments(
  int totalSize, {
  int maxSegmentSize = UploadLimits.maxSegmentSize,
}) {
  if (totalSize < 0) {
    throw ArgumentError.value(totalSize, 'totalSize', 'must be non-negative');
  }
  if (totalSize <= maxSegmentSize) {
    return [UploadSegment(index: 0, offset: 0, size: totalSize)];
  }

  final segments = <UploadSegment>[];
  var offset = 0;
  var index = 0;
  while (offset < totalSize) {
    final remaining = totalSize - offset;
    final size = remaining < maxSegmentSize ? remaining : maxSegmentSize;
    segments.add(UploadSegment(index: index, offset: offset, size: size));
    offset += size;
    index++;
  }
  return segments;
}
