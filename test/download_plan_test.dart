import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/download/download_plan.dart';

void main() {
  const mb = 1024 * 1024;

  group('downloadRanges', () {
    test('file smaller than one chunk yields a single window', () {
      final r = downloadRanges(1234);
      expect(r.length, 1);
      expect(r.single.offset, 0);
      expect(r.single.limit, DownloadLimits.chunkSize);
    });

    test('empty file yields no windows', () {
      expect(downloadRanges(0), isEmpty);
    });

    test('exact multiple of chunk size', () {
      final r = downloadRanges(3 * mb);
      expect(r.length, 3);
      expect(r.map((e) => e.offset), [0, mb, 2 * mb]);
    });

    test('partial last window still requested in full', () {
      final r = downloadRanges(2 * mb + 100);
      expect(r.length, 3);
      expect(r.last.offset, 2 * mb);
      expect(r.last.limit, DownloadLimits.chunkSize,
          reason: 'last window requests a full chunk; server returns fewer bytes');
    });

    test('offsets are 4KB-aligned as Telegram requires', () {
      final r = downloadRanges(10 * mb);
      for (final range in r) {
        expect(range.offset % 4096, 0);
      }
    });

    test('rejects negative size', () {
      expect(() => downloadRanges(-1), throwsArgumentError);
    });
  });
}
