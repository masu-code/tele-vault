import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/upload/upload_plan.dart';

void main() {
  const mb = 1024 * 1024;

  group('planSegments', () {
    test('small file is a single segment', () {
      final segs = planSegments(1234);
      expect(segs.length, 1);
      expect(segs.single.offset, 0);
      expect(segs.single.size, 1234);
    });

    test('empty file is a single zero-size segment', () {
      final segs = planSegments(0);
      expect(segs.length, 1);
      expect(segs.single.size, 0);
      // A zero-size segment still needs one (empty) upload part.
      expect(segs.single.chunkCount(), 1);
    });

    test('file exactly at the segment limit stays single', () {
      final segs = planSegments(UploadLimits.maxSegmentSize);
      expect(segs.length, 1);
    });

    test('file just over the limit splits into two', () {
      final segs = planSegments(UploadLimits.maxSegmentSize + 1);
      expect(segs.length, 2);
      expect(segs[0].size, UploadLimits.maxSegmentSize);
      expect(segs[1].size, 1);
    });

    test('segments are contiguous and cover the whole file', () {
      const total = 5_000 * mb; // ~5GB
      final segs = planSegments(total);

      // Offsets chain with no gaps or overlaps.
      var cursor = 0;
      for (final s in segs) {
        expect(s.offset, cursor);
        cursor += s.size;
      }
      expect(cursor, total, reason: 'segments must sum to the total size');

      // No segment exceeds the limit.
      for (final s in segs) {
        expect(s.size, lessThanOrEqualTo(UploadLimits.maxSegmentSize));
      }
    });

    test('rejects negative size', () {
      expect(() => planSegments(-1), throwsArgumentError);
    });
  });

  group('segment chunking', () {
    test('chunkCount rounds up partial chunks', () {
      const seg = UploadSegment(index: 0, offset: 0, size: UploadLimits.chunkSize + 1);
      expect(seg.chunkCount(), 2);
    });

    test('exact multiple of chunk size', () {
      const seg = UploadSegment(index: 0, offset: 0, size: UploadLimits.chunkSize * 3);
      expect(seg.chunkCount(), 3);
    });

    test('isBig threshold', () {
      expect(const UploadSegment(index: 0, offset: 0, size: UploadLimits.bigFileThreshold).isBig, isTrue);
      expect(const UploadSegment(index: 0, offset: 0, size: UploadLimits.bigFileThreshold - 1).isBig, isFalse);
    });

    test('a max-size segment stays within Telegram part cap', () {
      const seg = UploadSegment(index: 0, offset: 0, size: UploadLimits.maxSegmentSize);
      expect(seg.chunkCount(), lessThanOrEqualTo(UploadLimits.maxPartsPerFile));
    });
  });
}
