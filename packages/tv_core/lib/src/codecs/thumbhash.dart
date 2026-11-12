// Dart port of ThumbHash by Evan Wallace (MIT), see LICENSE-THIRD-PARTY.
// Reference: https://github.com/evanw/thumbhash (js/thumbhash.js).
//
// The port follows the reference line by line (same DCT layout, same bit
// packing, same rounding) so hashes are interchangeable with every other
// ThumbHash implementation.
import 'dart:math' as math;
import 'dart:typed_data';

/// JS `Math.round`: halves round towards +infinity.
int _round(double v) => (v + 0.5).floorToDouble().toInt();

/// Decoded ThumbHash image (at most 32 px on the long side).
class ThumbHashImage {
  const ThumbHashImage(this.width, this.height, this.rgba);
  final int width;
  final int height;

  /// Straight (non-premultiplied) RGBA, `width * height * 4` bytes.
  final Uint8List rgba;
}

/// Average colour of a ThumbHash, each channel in 0..1.
class ThumbHashAverage {
  const ThumbHashAverage(this.r, this.g, this.b, this.a);
  final double r, g, b, a;
}

class _Channel {
  _Channel(this.dc, this.ac, this.scale);
  final double dc;
  final List<double> ac;
  final double scale;
}

/// Encodes an RGBA image (straight alpha, `w * h * 4` bytes, at most 100x100)
/// into a ThumbHash (about 20-25 bytes).
Uint8List rgbaToThumbHash(int w, int h, Uint8List rgba) {
  if (w <= 0 || h <= 0) {
    throw ArgumentError('${w}x$h is not a valid image size');
  }
  if (w > 100 || h > 100) {
    throw ArgumentError('${w}x$h does not fit in 100x100');
  }
  if (rgba.length < w * h * 4) {
    throw ArgumentError('rgba has ${rgba.length} bytes, need ${w * h * 4}');
  }
  final count = w * h;

  // Determine the average color.
  var avgR = 0.0, avgG = 0.0, avgB = 0.0, avgA = 0.0;
  for (var i = 0, j = 0; i < count; i++, j += 4) {
    final alpha = rgba[j + 3] / 255;
    avgR += alpha / 255 * rgba[j];
    avgG += alpha / 255 * rgba[j + 1];
    avgB += alpha / 255 * rgba[j + 2];
    avgA += alpha;
  }
  if (avgA != 0) {
    avgR /= avgA;
    avgG /= avgA;
    avgB /= avgA;
  }

  final hasAlpha = avgA < count;
  final lLimit = hasAlpha ? 5 : 7; // fewer luminance bits if there's alpha
  final maxWH = math.max(w, h);
  final lx = math.max(1, _round(lLimit * w / maxWH));
  final ly = math.max(1, _round(lLimit * h / maxWH));
  final l = Float64List(count); // luminance
  final p = Float64List(count); // yellow - blue
  final q = Float64List(count); // red - green
  final a = Float64List(count); // alpha

  // Convert the image from RGBA to LPQA (composite atop the average color).
  for (var i = 0, j = 0; i < count; i++, j += 4) {
    final alpha = rgba[j + 3] / 255;
    final r = avgR * (1 - alpha) + alpha / 255 * rgba[j];
    final g = avgG * (1 - alpha) + alpha / 255 * rgba[j + 1];
    final b = avgB * (1 - alpha) + alpha / 255 * rgba[j + 2];
    l[i] = (r + g + b) / 3;
    p[i] = (r + g) / 2 - b;
    q[i] = r - g;
    a[i] = alpha;
  }

  // Encode using the DCT into DC (constant) and normalized AC (varying) terms.
  _Channel encodeChannel(Float64List channel, int nx, int ny) {
    var dc = 0.0;
    final ac = <double>[];
    var scale = 0.0;
    final fx = Float64List(w);
    for (var cy = 0; cy < ny; cy++) {
      for (var cx = 0; cx * ny < nx * (ny - cy); cx++) {
        var f = 0.0;
        for (var x = 0; x < w; x++) {
          fx[x] = math.cos(math.pi / w * cx * (x + 0.5));
        }
        for (var y = 0; y < h; y++) {
          final fy = math.cos(math.pi / h * cy * (y + 0.5));
          for (var x = 0; x < w; x++) {
            f += channel[x + y * w] * fx[x] * fy;
          }
        }
        f /= w * h;
        if (cx != 0 || cy != 0) {
          ac.add(f);
          scale = math.max(scale, f.abs());
        } else {
          dc = f;
        }
      }
    }
    if (scale != 0) {
      for (var i = 0; i < ac.length; i++) {
        ac[i] = 0.5 + 0.5 / scale * ac[i];
      }
    }
    return _Channel(dc, ac, scale);
  }

  final lC = encodeChannel(l, math.max(3, lx), math.max(3, ly));
  final pC = encodeChannel(p, 3, 3);
  final qC = encodeChannel(q, 3, 3);
  final aC = hasAlpha ? encodeChannel(a, 5, 5) : null;

  // Write the constants.
  final isLandscape = w > h;
  final header24 = _round(63 * lC.dc) |
      (_round(31.5 + 31.5 * pC.dc) << 6) |
      (_round(31.5 + 31.5 * qC.dc) << 12) |
      (_round(31 * lC.scale) << 18) |
      ((hasAlpha ? 1 : 0) << 23);
  final header16 = (isLandscape ? ly : lx) |
      (_round(63 * pC.scale) << 3) |
      (_round(63 * qC.scale) << 9) |
      ((isLandscape ? 1 : 0) << 15);
  final acStart = hasAlpha ? 6 : 5;
  final channels = hasAlpha ? [lC, pC, qC, aC!] : [lC, pC, qC];
  var acCount = 0;
  for (final c in channels) {
    acCount += c.ac.length;
  }
  final hash = Uint8List(acStart + ((acCount + 1) >> 1));
  hash[0] = header24 & 255;
  hash[1] = (header24 >> 8) & 255;
  hash[2] = (header24 >> 16) & 255;
  hash[3] = header16 & 255;
  hash[4] = (header16 >> 8) & 255;
  if (hasAlpha) {
    hash[5] = _round(15 * aC!.dc) | (_round(15 * aC.scale) << 4);
  }

  // Write the varying factors (two 4-bit values per byte).
  var acIndex = 0;
  for (final c in channels) {
    for (final f in c.ac) {
      hash[acStart + (acIndex >> 1)] |=
          _round(15 * f) << ((acIndex++ & 1) << 2);
    }
  }
  return hash;
}

int _acCount(int nx, int ny) {
  var n = 0;
  for (var cy = 0; cy < ny; cy++) {
    for (var cx = cy != 0 ? 0 : 1; cx * ny < nx * (ny - cy); cx++) {
      n++;
    }
  }
  return n;
}

/// Layout read from the 5-byte header.
class _Header {
  _Header(Uint8List hash)
      : header24 = hash[0] | (hash[1] << 8) | (hash[2] << 16),
        header16 = hash[3] | (hash[4] << 8) {
    hasAlpha = (header24 >> 23) != 0;
    isLandscape = (header16 >> 15) != 0;
    lx = math.max(3, isLandscape ? (hasAlpha ? 5 : 7) : header16 & 7);
    ly = math.max(3, isLandscape ? header16 & 7 : (hasAlpha ? 5 : 7));
    acStart = hasAlpha ? 6 : 5;
    final acTotal =
        _acCount(lx, ly) + 2 * _acCount(3, 3) + (hasAlpha ? _acCount(5, 5) : 0);
    expectedLength = acStart + ((acTotal + 1) >> 1);
  }
  final int header24;
  final int header16;
  late final bool hasAlpha;
  late final bool isLandscape;
  late final int lx;
  late final int ly;
  late final int acStart;
  late final int expectedLength;
}

/// Header of [hash], or null when it is too short to contain everything its
/// own header announces.
_Header? _parse(Uint8List hash) {
  if (hash.length < 5) return null;
  final h = _Header(hash);
  return hash.length >= h.expectedLength ? h : null;
}

/// Whether [hash] is structurally valid (long enough for its own header). The
/// decoding functions return null for invalid input instead of throwing.
bool isValidThumbHash(Uint8List hash) => _parse(hash) != null;

/// Decodes a ThumbHash into an RGBA image of at most 32 px on the long side,
/// or null if [hash] is malformed.
ThumbHashImage? thumbHashToRGBA(Uint8List hash) {
  final hd = _parse(hash);
  if (hd == null) return null;

  final header24 = hd.header24;
  final header16 = hd.header16;
  final lDc = (header24 & 63) / 63;
  final pDc = ((header24 >> 6) & 63) / 31.5 - 1;
  final qDc = ((header24 >> 12) & 63) / 31.5 - 1;
  final lScale = ((header24 >> 18) & 31) / 31;
  final hasAlpha = hd.hasAlpha;
  final pScale = ((header16 >> 3) & 63) / 63;
  final qScale = ((header16 >> 9) & 63) / 63;
  final lx = hd.lx, ly = hd.ly;
  final aDc = hasAlpha ? (hash[5] & 15) / 15 : 1.0;
  final aScale = hasAlpha ? (hash[5] >> 4) / 15 : 0.0;

  // Read the variable-length AC coefficients.
  final acStart = hd.acStart;
  var acIndex = 0;
  List<double> decodeChannel(int nx, int ny, double scale) {
    final ac = <double>[];
    for (var cy = 0; cy < ny; cy++) {
      for (var cx = cy != 0 ? 0 : 1; cx * ny < nx * (ny - cy); cx++) {
        final nibble =
            (hash[acStart + (acIndex >> 1)] >> ((acIndex++ & 1) << 2)) & 15;
        ac.add((nibble / 7.5 - 1) * scale);
      }
    }
    return ac;
  }

  final lAc = decodeChannel(lx, ly, lScale);
  final pAc = decodeChannel(3, 3, pScale * 1.25);
  final qAc = decodeChannel(3, 3, qScale * 1.25);
  final aAc = hasAlpha ? decodeChannel(5, 5, aScale) : const <double>[];

  // Decode using the DCT into RGB.
  final ratio = _ratio(hd);
  final w = math.max(1, _round(ratio > 1 ? 32 : 32 * ratio));
  final h = math.max(1, _round(ratio > 1 ? 32 / ratio : 32));
  final rgba = Uint8List(w * h * 4);
  final nfx = math.max(lx, hasAlpha ? 5 : 3);
  final nfy = math.max(ly, hasAlpha ? 5 : 3);
  final fx = Float64List(nfx);
  final fy = Float64List(nfy);
  for (var y = 0, i = 0; y < h; y++) {
    for (var cy = 0; cy < nfy; cy++) {
      fy[cy] = math.cos(math.pi / h * (y + 0.5) * cy);
    }
    for (var x = 0; x < w; x++, i += 4) {
      var l = lDc, p = pDc, q = qDc, a = aDc;

      // Precompute the coefficients.
      for (var cx = 0; cx < nfx; cx++) {
        fx[cx] = math.cos(math.pi / w * (x + 0.5) * cx);
      }

      // Decode L.
      for (var cy = 0, j = 0; cy < ly; cy++) {
        final fy2 = fy[cy] * 2;
        for (var cx = cy != 0 ? 0 : 1; cx * ly < lx * (ly - cy); cx++, j++) {
          l += lAc[j] * fx[cx] * fy2;
        }
      }

      // Decode P and Q.
      for (var cy = 0, j = 0; cy < 3; cy++) {
        final fy2 = fy[cy] * 2;
        for (var cx = cy != 0 ? 0 : 1; cx < 3 - cy; cx++, j++) {
          final f = fx[cx] * fy2;
          p += pAc[j] * f;
          q += qAc[j] * f;
        }
      }

      // Decode A.
      if (hasAlpha) {
        for (var cy = 0, j = 0; cy < 5; cy++) {
          final fy2 = fy[cy] * 2;
          for (var cx = cy != 0 ? 0 : 1; cx < 5 - cy; cx++, j++) {
            a += aAc[j] * fx[cx] * fy2;
          }
        }
      }

      // Convert to RGB.
      final b = l - 2 / 3 * p;
      final r = (3 * l - b + q) / 2;
      final g = r - q;
      rgba[i] = math.max(0.0, 255 * math.min(1.0, r)).toInt();
      rgba[i + 1] = math.max(0.0, 255 * math.min(1.0, g)).toInt();
      rgba[i + 2] = math.max(0.0, 255 * math.min(1.0, b)).toInt();
      rgba[i + 3] = math.max(0.0, 255 * math.min(1.0, a)).toInt();
    }
  }
  return ThumbHashImage(w, h, rgba);
}

/// Extracts the average colour from a ThumbHash, or null if malformed.
ThumbHashAverage? thumbHashToAverageRGBA(Uint8List hash) {
  final hd = _parse(hash);
  if (hd == null) return null;
  final l = (hd.header24 & 63) / 63;
  final p = ((hd.header24 >> 6) & 63) / 31.5 - 1;
  final q = ((hd.header24 >> 12) & 63) / 31.5 - 1;
  final a = hd.hasAlpha ? (hash[5] & 15) / 15 : 1.0;
  final b = l - 2 / 3 * p;
  final r = (3 * l - b + q) / 2;
  final g = r - q;
  double c(double v) => math.max(0.0, math.min(1.0, v));
  return ThumbHashAverage(c(r), c(g), c(b), a);
}

double _ratio(_Header hd) {
  final lx = hd.isLandscape ? (hd.hasAlpha ? 5 : 7) : hd.header16 & 7;
  final ly = hd.isLandscape ? hd.header16 & 7 : (hd.hasAlpha ? 5 : 7);
  // Valid hashes always have lx, ly >= 1; guard the degenerate forged case.
  return math.max(1, lx) / math.max(1, ly);
}

/// Approximate width/height ratio of the original image, or null if [hash] is
/// malformed.
double? thumbHashToApproximateAspectRatio(Uint8List hash) {
  final hd = _parse(hash);
  return hd == null ? null : _ratio(hd);
}
