import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:tv_core/codecs.dart';

Uint8List solid(int w, int h, int r, int g, int b) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = 255;
  }
  return px;
}

Uint8List jpegOf(int w, int h,
    {int r = 200, int g = 80, int b = 40, int? orientation}) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

void main() {
  group('PreviewCodec wire form', () {
    test('toWire/fromWire round trip', () {
      final hash = PreviewCodec.encodeRgba(solid(20, 20, 10, 20, 30), 20, 20)!;
      final wire = PreviewCodec.toWire(hash);
      expect(wire, startsWith('th1:'));
      expect(PreviewCodec.fromWire(wire), hash);
    });

    test('fromWire rejects garbage without throwing', () {
      for (final bad in [
        '',
        'th1:',
        'th2:AAAA',
        'AAAA',
        'th1:!!!not base64!!!',
        'th1:AAAA', // valid base64, hash too short
        'th1:${'A' * 400}', // too long
        'TH1:AAAAAAAAAAAA',
      ]) {
        expect(PreviewCodec.fromWire(bad), isNull, reason: bad);
        expect(PreviewCodec.decode(bad), isNull, reason: bad);
        expect(PreviewCodec.averageArgb(bad), isNull, reason: bad);
        expect(PreviewCodec.aspectRatio(bad), isNull, reason: bad);
      }
    });

    test('fromWire never throws on random strings', () {
      final rnd = math.Random(99);
      for (var n = 0; n < 2000; n++) {
        final s =
            'th1:${String.fromCharCodes(List.generate(rnd.nextInt(60), (_) => 33 + rnd.nextInt(90)))}';
        PreviewCodec.fromWire(s);
        PreviewCodec.decode(s);
      }
    });
  });

  group('PreviewCodec encode/decode', () {
    test('encodeRgba + decode of a solid colour', () {
      final hash =
          PreviewCodec.encodeRgba(solid(30, 20, 200, 100, 50), 30, 20)!;
      final wire = PreviewCodec.toWire(hash);
      final px = PreviewCodec.decode(wire)!;
      expect(math.max(px.width, px.height), 32);
      expect(px.rgba.length, px.width * px.height * 4);
      expect((px.rgba[0] - 200).abs(), lessThanOrEqualTo(3));
      expect((px.rgba[1] - 100).abs(), lessThanOrEqualTo(3));
      expect((px.rgba[2] - 50).abs(), lessThanOrEqualTo(3));
      final argb = PreviewCodec.averageArgb(wire)!;
      expect(argb >> 24, 255);
      expect((((argb >> 16) & 255) - 200).abs(), lessThanOrEqualTo(3));
      expect(PreviewCodec.aspectRatio(wire)!, closeTo(1.5, 0.15));
    });

    test('encodeRgba box-downscales large input', () {
      // 400x300: left half red, right half blue.
      const w = 400, h = 300;
      final px = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          px[i] = x < w ~/ 2 ? 255 : 0;
          px[i + 2] = x < w ~/ 2 ? 0 : 255;
          px[i + 3] = 255;
        }
      }
      final hash = PreviewCodec.encodeRgba(px, w, h)!;
      expect(hash.length, lessThanOrEqualTo(25));
      final dec = PreviewCodec.decode(PreviewCodec.toWire(hash))!;
      final row = dec.height ~/ 2;
      expect(dec.rgba[(row * dec.width + 2) * 4], greaterThan(200)); // red left
      expect(dec.rgba[(row * dec.width + dec.width - 3) * 4 + 2],
          greaterThan(200)); // blue right
      expect(PreviewCodec.aspectRatio(PreviewCodec.toWire(hash))!,
          closeTo(4 / 3, 0.14));
    });

    test('encodeRgba returns null for malformed input', () {
      expect(PreviewCodec.encodeRgba(Uint8List(3), 10, 10), isNull);
      expect(PreviewCodec.encodeRgba(Uint8List(0), 0, 0), isNull);
    });

    test('encodeJpeg decodes a real JPEG', () {
      final hash = PreviewCodec.encodeJpeg(jpegOf(320, 240))!;
      final wire = PreviewCodec.toWire(hash);
      final px = PreviewCodec.decode(wire)!;
      expect((px.rgba[0] - 200).abs(), lessThanOrEqualTo(8)); // JPEG loss
      expect((px.rgba[1] - 80).abs(), lessThanOrEqualTo(8));
      expect((px.rgba[2] - 40).abs(), lessThanOrEqualTo(8));
      expect(PreviewCodec.aspectRatio(wire)!, closeTo(4 / 3, 0.14));
    });

    test('encodeJpeg honours EXIF orientation', () {
      // 80x40 stored landscape, orientation 6 = rotate 90: displays portrait.
      final hash = PreviewCodec.encodeJpeg(jpegOf(80, 40, orientation: 6))!;
      expect(PreviewCodec.aspectRatio(PreviewCodec.toWire(hash))!, lessThan(1));
    });

    test('encodeJpeg returns null on garbage', () {
      expect(PreviewCodec.encodeJpeg(Uint8List(0)), isNull);
      expect(
          PreviewCodec.encodeJpeg(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
      final j = jpegOf(64, 64);
      expect(
          () => PreviewCodec.encodeJpeg(
              Uint8List.sublistView(j, 0, j.length ~/ 3)),
          returnsNormally); // truncated: null or best-effort, never throws
    });
  });
}
