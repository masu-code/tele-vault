import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:tv_core/codecs.dart';

Uint8List jpegOf(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(10, 120, 200));
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

void main() {
  group('crc32', () {
    test('check value of "123456789"', () {
      expect(crc32(utf8.encode('123456789')), 0xCBF43926);
    });
    test('empty and known values', () {
      expect(crc32(const []), 0);
      expect(crc32(utf8.encode('a')), 0xE8B7BE43);
      expect(crc32(utf8.encode('The quick brown fox jumps over the lazy dog')),
          0x414FA339);
    });
    test('incremental equals one-shot', () {
      final rnd = math.Random(1);
      final data =
          Uint8List.fromList(List.generate(5000, (_) => rnd.nextInt(256)));
      final whole = crc32(data);
      var c = 0;
      for (var i = 0; i < data.length; i += 777) {
        c = crc32(data, crc: c, start: i, end: math.min(i + 777, data.length));
      }
      expect(c, whole);
    });
    test('range checks', () {
      expect(() => crc32(Uint8List(4), start: 3, end: 2), throwsRangeError);
      expect(() => crc32(Uint8List(4), end: 9), throwsRangeError);
    });
    test('views are read at their own offset', () {
      final data = Uint8List.fromList(utf8.encode('xx123456789yy'));
      expect(crc32(Uint8List.sublistView(data, 2, 11)), 0xCBF43926);
    });
  });

  group('jpegSize', () {
    test('reads real JPEG dimensions', () {
      for (final s in const [
        (1, 1),
        (16, 16),
        (320, 200),
        (200, 320),
        (97, 53)
      ]) {
        final r = jpegSize(jpegOf(s.$1, s.$2));
        expect(r, isNotNull, reason: '${s.$1}x${s.$2}');
        expect(r!.w, s.$1);
        expect(r.h, s.$2);
      }
    });

    test('reads progressive (SOF2) header', () {
      final j = jpegOf(40, 30);
      // Find SOF0 and flip it to SOF2: header parse must still work.
      for (var i = 0; i < j.length - 1; i++) {
        if (j[i] == 0xFF && j[i + 1] == 0xC0) {
          j[i + 1] = 0xC2;
          break;
        }
      }
      final r = jpegSize(j)!;
      expect((r.w, r.h), (40, 30));
    });

    test('null for non-JPEG', () {
      expect(jpegSize(Uint8List(0)), isNull);
      expect(jpegSize(Uint8List.fromList([0xFF, 0xD8])), isNull);
      expect(
          jpegSize(Uint8List.fromList(
              [0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])),
          isNull);
      expect(
          jpegSize(Uint8List.fromList(utf8.encode('GIF89a not a jpeg at all'))),
          isNull);
    });

    test('never throws on every truncation of a real JPEG', () {
      final j = jpegOf(64, 48);
      for (var n = 0; n <= j.length; n++) {
        expect(() => jpegSize(Uint8List.sublistView(j, 0, n)), returnsNormally,
            reason: 'len $n');
      }
    });

    test('never throws on random bytes, even behind a valid SOI', () {
      final rnd = math.Random(555);
      for (var n = 0; n < 20000; n++) {
        final len = rnd.nextInt(80);
        final b = Uint8List(len);
        for (var i = 0; i < len; i++) {
          // Bias towards marker-ish values to reach deeper branches.
          b[i] = rnd.nextInt(3) == 0 ? 0xFF : rnd.nextInt(256);
        }
        if (len >= 2 && rnd.nextBool()) {
          b[0] = 0xFF;
          b[1] = 0xD8;
        }
        expect(() => jpegSize(b), returnsNormally);
      }
    });

    test('never throws on mutated real JPEG headers', () {
      final j = jpegOf(64, 48);
      final rnd = math.Random(8);
      for (var n = 0; n < 5000; n++) {
        final b = Uint8List.fromList(j);
        for (var k = 0; k < 1 + rnd.nextInt(4); k++) {
          b[rnd.nextInt(math.min(b.length, 200))] = rnd.nextInt(256);
        }
        expect(() => jpegSize(b), returnsNormally);
      }
    });

    test('zero-length and tiny segment lengths terminate', () {
      // SOI, APP0 with len 0, then more APP0 len 0 ... must not loop forever.
      final b = Uint8List.fromList([
        0xFF,
        0xD8,
        ...List.generate(40, (i) => i.isEven ? 0xFF : 0xE0),
        ...List.filled(20, 0),
      ]);
      expect(jpegSize(b), isNull);
      // Fill bytes run.
      expect(
          jpegSize(Uint8List.fromList([0xFF, 0xD8, ...List.filled(30, 0xFF)])),
          isNull);
    });

    test('matches the original app implementation on valid JPEGs', () {
      // Original _jpegSize (upload_service.dart) copied here for equivalence.
      ({int w, int h})? original(Uint8List bytes) {
        if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8)
          return null;
        var i = 2;
        while (i + 9 < bytes.length) {
          if (bytes[i] != 0xFF) return null;
          final marker = bytes[i + 1];
          if (marker == 0xFF) {
            i++;
            continue;
          }
          if (marker >= 0xC0 &&
              marker <= 0xCF &&
              marker != 0xC4 &&
              marker != 0xC8 &&
              marker != 0xCC) {
            final h = (bytes[i + 5] << 8) | bytes[i + 6];
            final w = (bytes[i + 7] << 8) | bytes[i + 8];
            return (w: w, h: h);
          }
          i += 2 + ((bytes[i + 2] << 8) | bytes[i + 3]);
        }
        return null;
      }

      for (final s in const [(8, 8), (123, 77), (640, 480), (31, 500)]) {
        final j = jpegOf(s.$1, s.$2);
        expect(jpegSize(j), original(j));
      }
    });
  });
}
