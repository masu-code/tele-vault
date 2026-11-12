import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tv_core/codecs.dart';

/// ThumbHash stores DC as 6 bits (L) / 6 bits (P, Q). Worst case after the
/// YPQ -> RGB conversion: 2.0 (L) + 1.35 (P/3) + 2.0 (Q/2) = 5.4, plus the
/// final truncation -> 6. (+-3, as the plan assumed, is not attainable by
/// design; an exhaustive sweep of the colour cube peaks at 6.)
const _solidTol = 6;

Uint8List solid(int w, int h, int r, int g, int b, [int a = 255]) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = a;
  }
  return px;
}

/// Left-to-right grey ramp 0..255.
Uint8List ramp(int w, int h) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = (x * 255 / (w - 1)).round();
      final i = (y * w + x) * 4;
      px[i] = v;
      px[i + 1] = v;
      px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return px;
}

void main() {
  group('thumbhash encode/decode', () {
    test('solid colours decode within quantisation error per channel', () {
      const colours = [
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [255, 255, 255],
        [0, 0, 0],
        [128, 128, 128],
        [200, 120, 40],
        [30, 90, 160],
        [250, 240, 10],
        [12, 200, 180],
      ];
      for (final c in colours) {
        final hash = rgbaToThumbHash(64, 48, solid(64, 48, c[0], c[1], c[2]));
        final img = thumbHashToRGBA(hash)!;
        for (var i = 0; i < img.width * img.height; i++) {
          for (var k = 0; k < 3; k++) {
            expect((img.rgba[i * 4 + k] - c[k]).abs(),
                lessThanOrEqualTo(_solidTol),
                reason: 'colour $c channel $k pixel $i');
          }
          expect(img.rgba[i * 4 + 3], 255);
        }
      }
    });

    test('random solid colours stay within quantisation error', () {
      final rnd = math.Random(7);
      for (var n = 0; n < 200; n++) {
        final c = [rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256)];
        final hash = rgbaToThumbHash(20, 20, solid(20, 20, c[0], c[1], c[2]));
        final img = thumbHashToRGBA(hash)!;
        for (var k = 0; k < 3; k++) {
          expect((img.rgba[k] - c[k]).abs(), lessThanOrEqualTo(_solidTol),
              reason: 'colour $c channel $k');
        }
      }
    });

    test('average colour of a solid image matches', () {
      final hash = rgbaToThumbHash(40, 40, solid(40, 40, 200, 100, 50));
      final avg = thumbHashToAverageRGBA(hash)!;
      expect((avg.r * 255 - 200).abs(), lessThanOrEqualTo(3));
      expect((avg.g * 255 - 100).abs(), lessThanOrEqualTo(3));
      expect((avg.b * 255 - 50).abs(), lessThanOrEqualTo(3));
      expect(avg.a, 1.0);
    });

    test('grey gradient decodes monotonic left to right', () {
      for (final size in const [(100, 100), (100, 40), (40, 100)]) {
        final hash = rgbaToThumbHash(size.$1, size.$2, ramp(size.$1, size.$2));
        final img = thumbHashToRGBA(hash)!;
        final y = img.height ~/ 2;
        var prev = -1;
        for (var x = 0; x < img.width; x++) {
          final v = img.rgba[(y * img.width + x) * 4];
          // Band-limited reconstruction: allow tiny ringing, no real reversal.
          expect(v, greaterThanOrEqualTo(prev - 8),
              reason: 'x=$x ${size.$1}x${size.$2}');
          prev = math.max(prev, v);
        }
        expect(img.rgba[(y * img.width + img.width - 1) * 4],
            greaterThan(img.rgba[y * img.width * 4] + 100));
      }
    });

    test('vertical gradient decodes monotonic top to bottom', () {
      const w = 60, h = 80;
      final px = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final v = (255 - y * 255 / (h - 1)).round();
          px[i] = v;
          px[i + 1] = v;
          px[i + 2] = v;
          px[i + 3] = 255;
        }
      }
      final img = thumbHashToRGBA(rgbaToThumbHash(w, h, px))!;
      var prev = 256;
      for (var y = 0; y < img.height; y++) {
        final v = img.rgba[(y * img.width + img.width ~/ 2) * 4];
        // 4-bit AC quantisation + truncated DCT overshoot near the ends (observed ~14); the strict check is the quartile ordering below.
        expect(v, lessThanOrEqualTo(prev + 20), reason: 'y=$y');
        prev = math.min(prev, v);
      }
      int at(double f) =>
          img.rgba[((img.height - 1) * f).round() * img.width * 4 +
              (img.width ~/ 2) * 4];
      // Zero AC terms are not representable (4-bit levels at +-0.067), hence
      // the ripple; the trend must still be strictly decreasing.
      expect(at(0.15), greaterThan(at(0.4)));
      expect(at(0.4), greaterThan(at(0.65)));
      expect(at(0.65), greaterThan(at(0.9)));
      expect(at(0.15) - at(0.9), greaterThan(150));
    });

    test('aspect ratio within 15 percent for every ratio in [0.5, 2]', () {
      // The ratio is lx/ly with lx, ly <= 7 integers, so 2:1 (7/4) is 12.5 %
      // off and the worst case in this range is ~14.3 % (20x40). Inherent.
      for (var w = 20; w <= 100; w += 3) {
        for (var h = 20; h <= 100; h += 3) {
          final t = w / h;
          if (t < 0.5 || t > 2) continue;
          final hash = rgbaToThumbHash(w, h, solid(w, h, 90, 90, 90));
          final ar = thumbHashToApproximateAspectRatio(hash)!;
          expect((ar - t).abs() / t, lessThan(0.15), reason: '${w}x$h -> $ar');
        }
      }
    });

    test('aspect ratio within 10 percent for common photo ratios', () {
      const sizes = [
        (100, 100),
        (100, 75),
        (75, 100),
        (80, 60),
        (60, 80),
        (100, 56),
        (56, 100),
        (90, 60),
        (60, 90),
        (100, 80),
        (80, 100),
      ];
      for (final s in sizes) {
        final hash = rgbaToThumbHash(s.$1, s.$2, ramp(s.$1, s.$2));
        final ar = thumbHashToApproximateAspectRatio(hash)!;
        final truth = s.$1 / s.$2;
        expect((ar - truth).abs() / truth, lessThan(0.10),
            reason: '${s.$1}x${s.$2} -> $ar');
        final img = thumbHashToRGBA(hash)!;
        expect(math.max(img.width, img.height), 32);
        expect((img.width / img.height - ar).abs() / ar, lessThan(0.10));
      }
    });

    test('hash is at most 25 bytes, with and without alpha', () {
      final rnd = math.Random(3);
      for (var n = 0; n < 60; n++) {
        final w = 1 + rnd.nextInt(100), h = 1 + rnd.nextInt(100);
        final px = Uint8List(w * h * 4);
        for (var i = 0; i < px.length; i++) {
          px[i] = rnd.nextInt(256);
        }
        final withAlpha = rgbaToThumbHash(w, h, px);
        for (var i = 3; i < px.length; i += 4) {
          px[i] = 255;
        }
        final opaque = rgbaToThumbHash(w, h, px);
        expect(withAlpha.length, lessThanOrEqualTo(25));
        expect(opaque.length, lessThanOrEqualTo(25));
        expect(isValidThumbHash(withAlpha), isTrue);
        expect(isValidThumbHash(opaque), isTrue);
      }
    });

    test('encoding is deterministic', () {
      final rnd = math.Random(11);
      final px = Uint8List(50 * 30 * 4);
      for (var i = 0; i < px.length; i++) {
        px[i] = rnd.nextInt(256);
      }
      final a = rgbaToThumbHash(50, 30, px);
      final b = rgbaToThumbHash(50, 30, Uint8List.fromList(px));
      expect(a, b);
      expect(thumbHashToRGBA(a)!.rgba, thumbHashToRGBA(b)!.rgba);
    });

    test('alpha: transparent half decodes transparent, opaque half opaque', () {
      const w = 40, h = 40;
      final px = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          px[i] = 200;
          px[i + 1] = 50;
          px[i + 2] = 50;
          px[i + 3] = x < w ~/ 2 ? 255 : 0;
        }
      }
      final hash = rgbaToThumbHash(w, h, px);
      expect(hash[2] & 0x80, isNot(0), reason: 'hasAlpha flag');
      final img = thumbHashToRGBA(hash)!;
      final y = img.height ~/ 2;
      final left = img.rgba[(y * img.width + 2) * 4 + 3];
      final right = img.rgba[(y * img.width + img.width - 3) * 4 + 3];
      expect(left, greaterThan(200));
      expect(right, lessThan(55));
      // Colour of the opaque side is preserved.
      expect((img.rgba[(y * img.width + 2) * 4] - 200).abs(), lessThan(12));
    });

    test('fully transparent image does not blow up', () {
      final hash = rgbaToThumbHash(10, 10, Uint8List(400));
      final img = thumbHashToRGBA(hash)!;
      for (var i = 0; i < img.width * img.height; i++) {
        expect(img.rgba[i * 4 + 3], lessThan(10));
      }
    });

    test('average colour tracks the true mean of random images', () {
      final rnd = math.Random(5);
      for (var n = 0; n < 40; n++) {
        const w = 24, h = 24;
        final px = Uint8List(w * h * 4);
        var sr = 0, sg = 0, sb = 0;
        // Smooth-ish random image: random base plus a gentle gradient.
        final base = [rnd.nextInt(180), rnd.nextInt(180), rnd.nextInt(180)];
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 4;
            px[i] = base[0] + x * 2;
            px[i + 1] = base[1] + y * 2;
            px[i + 2] = base[2] + (x + y);
            px[i + 3] = 255;
            sr += px[i];
            sg += px[i + 1];
            sb += px[i + 2];
          }
        }
        final avg = thumbHashToAverageRGBA(rgbaToThumbHash(w, h, px))!;
        expect((avg.r * 255 - sr / (w * h)).abs(), lessThan(5));
        expect((avg.g * 255 - sg / (w * h)).abs(), lessThan(5));
        expect((avg.b * 255 - sb / (w * h)).abs(), lessThan(5));
      }
    });

    test('decode then re-encode is stable (idempotent within quantisation)',
        () {
      final rnd = math.Random(9);
      for (var n = 0; n < 20; n++) {
        const w = 32, h = 32;
        final px = Uint8List(w * h * 4);
        final f = 1 + rnd.nextInt(3);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final i = (y * w + x) * 4;
            px[i] = (127 + 120 * math.sin(x * f / 6.0)).round();
            px[i + 1] = (127 + 120 * math.cos(y * f / 7.0)).round();
            px[i + 2] = (x * 8) & 255;
            px[i + 3] = 255;
          }
        }
        final first = thumbHashToRGBA(rgbaToThumbHash(w, h, px))!;
        final second = thumbHashToRGBA(
            rgbaToThumbHash(first.width, first.height, first.rgba))!;
        var err = 0;
        for (var i = 0; i < first.rgba.length; i += 4) {
          err += (first.rgba[i] - second.rgba[i]).abs();
        }
        expect(err / (first.width * first.height), lessThan(14));
      }
    });

    test('invalid sizes throw ArgumentError on encode', () {
      expect(() => rgbaToThumbHash(101, 10, Uint8List(101 * 10 * 4)),
          throwsArgumentError);
      expect(() => rgbaToThumbHash(10, 101, Uint8List(101 * 10 * 4)),
          throwsArgumentError);
      expect(() => rgbaToThumbHash(0, 10, Uint8List(0)), throwsArgumentError);
      expect(() => rgbaToThumbHash(10, 10, Uint8List(10)), throwsArgumentError);
    });

    test('1x1 and extreme aspect ratios encode and decode', () {
      for (final s in const [(1, 1), (1, 100), (100, 1), (2, 100)]) {
        final hash =
            rgbaToThumbHash(s.$1, s.$2, solid(s.$1, s.$2, 90, 160, 220));
        final img = thumbHashToRGBA(hash)!;
        expect(img.width, inInclusiveRange(1, 32));
        expect(img.height, inInclusiveRange(1, 32));
        expect(img.rgba.length, img.width * img.height * 4);
      }
    });

    test('decoders never throw on malformed hashes', () {
      final rnd = math.Random(1234);
      for (var n = 0; n < 5000; n++) {
        final len = rnd.nextInt(40);
        final b = Uint8List(len);
        for (var i = 0; i < len; i++) {
          b[i] = rnd.nextInt(256);
        }
        final img = thumbHashToRGBA(b);
        expect(thumbHashToAverageRGBA(b) == null, img == null);
        expect(thumbHashToApproximateAspectRatio(b) == null, img == null);
        expect(isValidThumbHash(b), img != null);
        if (img != null) {
          expect(img.width, inInclusiveRange(1, 32));
          expect(img.height, inInclusiveRange(1, 32));
          expect(img.rgba.length, img.width * img.height * 4);
        }
      }
      expect(thumbHashToRGBA(Uint8List(0)), isNull);
      expect(thumbHashToRGBA(Uint8List(4)), isNull);
    });

    test('decode micro-benchmark', () {
      final rnd = math.Random(21);
      final hashes = <Uint8List>[];
      for (var n = 0; n < 50; n++) {
        final px = Uint8List(32 * 24 * 4);
        for (var i = 0; i < px.length; i++) {
          px[i] = rnd.nextInt(256);
        }
        hashes.add(rgbaToThumbHash(32, 24, px));
      }
      for (final h in hashes) {
        thumbHashToRGBA(h); // warm-up
      }
      final sw = Stopwatch()..start();
      const rounds = 10;
      for (var r = 0; r < rounds; r++) {
        for (final h in hashes) {
          thumbHashToRGBA(h);
        }
      }
      sw.stop();
      final perMs = sw.elapsedMicroseconds / 1000 / (rounds * hashes.length);
      // ignore: avoid_print
      print('BENCH thumbHashToRGBA: ${perMs.toStringAsFixed(3)} ms per hash '
          '(JIT, expect < 0.3 ms)');
      expect(perMs, lessThan(2.0)); // generous: JIT + loaded CI machines
    });
  });
}
