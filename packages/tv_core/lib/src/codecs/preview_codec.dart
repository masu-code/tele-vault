import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'thumbhash.dart';

/// Decoded preview, at most 32 px on the long side.
class PreviewPixels {
  const PreviewPixels({
    required this.width,
    required this.height,
    required this.rgba,
  });
  final int width;
  final int height;

  /// Straight RGBA, `width * height * 4` bytes.
  final Uint8List rgba;
}

/// ThumbHash-based tiny previews, stored in the index as `th1:<base64>`.
abstract final class PreviewCodec {
  static const String wirePrefix = 'th1:';

  /// Longest side fed to the ThumbHash encoder.
  static const int maxEncodeSide = 100;

  /// Hashes are 20-25 bytes; anything much larger is not ours.
  static const int _maxHashBytes = 64;

  /// Encodes straight RGBA pixels (`w * h * 4` bytes, any size) into a
  /// ThumbHash. Images larger than 100 px are box-downscaled first.
  /// Returns null when the input is malformed.
  static Uint8List? encodeRgba(Uint8List rgba, int w, int h) {
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return null;
    if (w <= maxEncodeSide && h <= maxEncodeSide) {
      return rgbaToThumbHash(w, h, rgba);
    }
    final scale = maxEncodeSide / math.max(w, h);
    final tw = math.max(1, (w * scale).round());
    final th = math.max(1, (h * scale).round());
    return rgbaToThumbHash(tw, th, _boxDownscale(rgba, w, h, tw, th));
  }

  /// Decodes [jpeg], applies its EXIF orientation, downsizes and hashes it.
  /// Returns null on any error. Full JPEG decode in pure Dart: NOT for hot
  /// paths (use the platform thumbnail + [encodeRgba] there).
  static Uint8List? encodeJpeg(Uint8List jpeg) {
    try {
      var image = img.decodeJpg(jpeg);
      if (image == null) return null;
      image = img.bakeOrientation(image);
      final longest = math.max(image.width, image.height);
      if (longest > maxEncodeSide) {
        final s = maxEncodeSide / longest;
        image = img.copyResize(
          image,
          width: math.max(1, (image.width * s).round()),
          height: math.max(1, (image.height * s).round()),
          interpolation: img.Interpolation.average,
        );
      }
      image = image.convert(format: img.Format.uint8, numChannels: 4);
      final rgba = image.getBytes(order: img.ChannelOrder.rgba);
      return rgbaToThumbHash(image.width, image.height, rgba);
    } catch (_) {
      return null;
    }
  }

  /// `th1:<base64>` -> pixels (at most 32 px on the long side), or null.
  static PreviewPixels? decode(String wire) {
    final hash = fromWire(wire);
    if (hash == null) return null;
    final image = thumbHashToRGBA(hash);
    if (image == null) return null;
    return PreviewPixels(
      width: image.width,
      height: image.height,
      rgba: image.rgba,
    );
  }

  /// Average colour as 0xAARRGGBB, or null if [wire] is invalid.
  static int? averageArgb(String wire) {
    final hash = fromWire(wire);
    if (hash == null) return null;
    final c = thumbHashToAverageRGBA(hash);
    if (c == null) return null;
    int ch(double v) => (v * 255).round().clamp(0, 255);
    return (ch(c.a) << 24) | (ch(c.r) << 16) | (ch(c.g) << 8) | ch(c.b);
  }

  /// Approximate width / height of the original image, or null if invalid.
  static double? aspectRatio(String wire) {
    final hash = fromWire(wire);
    return hash == null ? null : thumbHashToApproximateAspectRatio(hash);
  }

  /// Raw hash -> `th1:<standard base64>`.
  static String toWire(Uint8List hash) => '$wirePrefix${base64.encode(hash)}';

  /// `th1:<base64>` -> raw hash; null when the prefix, the base64 or the hash
  /// structure is invalid. Never throws.
  static Uint8List? fromWire(String wire) {
    if (!wire.startsWith(wirePrefix)) return null;
    final body = wire.substring(wirePrefix.length);
    if (body.isEmpty || body.length > _maxHashBytes * 2) return null;
    try {
      final hash = base64.decode(body);
      if (hash.length > _maxHashBytes || !isValidThumbHash(hash)) return null;
      return hash;
    } catch (_) {
      return null;
    }
  }
}

/// Area-averaging downscale of straight RGBA (alpha-weighted so transparent
/// pixels do not bleed their colour).
Uint8List _boxDownscale(Uint8List src, int sw, int sh, int tw, int th) {
  final out = Uint8List(tw * th * 4);
  for (var ty = 0; ty < th; ty++) {
    final y0 = ty * sh ~/ th;
    final y1 = math.max(y0 + 1, (ty + 1) * sh ~/ th);
    for (var tx = 0; tx < tw; tx++) {
      final x0 = tx * sw ~/ tw;
      final x1 = math.max(x0 + 1, (tx + 1) * sw ~/ tw);
      var r = 0, g = 0, b = 0, a = 0, n = 0;
      for (var y = y0; y < y1; y++) {
        var i = (y * sw + x0) * 4;
        for (var x = x0; x < x1; x++, i += 4) {
          final al = src[i + 3];
          r += src[i] * al;
          g += src[i + 1] * al;
          b += src[i + 2] * al;
          a += al;
          n++;
        }
      }
      final o = (ty * tw + tx) * 4;
      if (a > 0) {
        out[o] = (r / a).round();
        out[o + 1] = (g / a).round();
        out[o + 2] = (b / a).round();
      }
      out[o + 3] = (a / n).round();
    }
  }
  return out;
}
