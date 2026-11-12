import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/download/download_plan.dart';
import 'package:tg/tg.dart' show TgCrypto;

void main() {
  const mb = 1024 * 1024;
  final chunk = DownloadLimits.chunkSize;

  group('downloadRanges', () {
    test('chunk size satisfies getFile rules (divides 1 MB, 4 KB multiple)', () {
      for (final c in [
        chunk,
        DownloadLimits.nativeChunkSize,
        DownloadLimits.dartChunkSize,
      ]) {
        expect(mb % c, 0);
        expect(c % 4096, 0);
      }
    });

    test('chunk size follows the crypto backend', () {
      expect(
        chunk,
        TgCrypto.backend.name == 'native'
            ? DownloadLimits.nativeChunkSize
            : DownloadLimits.dartChunkSize,
      );
    });

    test('explicit chunk size overrides the backend default', () {
      final r = downloadRanges(300 * 1024, chunkSize: 128 * 1024);
      expect(r.map((e) => e.offset), [0, 128 * 1024, 256 * 1024]);
    });

    test('file smaller than one chunk yields a single window', () {
      final r = downloadRanges(1234);
      expect(r.length, 1);
      expect(r.single.offset, 0);
      expect(r.single.limit, chunk);
    });

    test('empty file yields no windows', () {
      expect(downloadRanges(0), isEmpty);
    });

    test('exact multiple of chunk size', () {
      final r = downloadRanges(3 * chunk);
      expect(r.length, 3);
      expect(r.map((e) => e.offset), [0, chunk, 2 * chunk]);
    });

    test('partial last window still requested in full', () {
      final r = downloadRanges(2 * chunk + 100);
      expect(r.length, 3);
      expect(r.last.offset, 2 * chunk);
      expect(r.last.limit, chunk,
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
