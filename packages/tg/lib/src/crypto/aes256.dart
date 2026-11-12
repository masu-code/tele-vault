import 'dart:typed_data';

// Pure-Dart AES-256 (FIPS-197) with 32-bit T-tables.
//
// Words are little-endian packings of 4 consecutive state bytes (byte r of a
// column sits at bits 8r), which matches how `Uint32List` views read a
// `Uint8List` on every platform Dart runs on. The key schedule is expanded
// once per [Aes256] object; block functions allocate nothing.

const int _nr = 14; // rounds for a 256-bit key
const int _rkWords = 4 * (_nr + 1); // 60

final Uint8List _sbox = Uint8List(256);
final Uint8List _invSbox = Uint8List(256);
final Uint32List _te0 = Uint32List(256);
final Uint32List _te1 = Uint32List(256);
final Uint32List _te2 = Uint32List(256);
final Uint32List _te3 = Uint32List(256);
final Uint32List _td0 = Uint32List(256);
final Uint32List _td1 = Uint32List(256);
final Uint32List _td2 = Uint32List(256);
final Uint32List _td3 = Uint32List(256);
bool _tablesReady = false;

int _rotl32(int v, int n) => ((v << n) | (v >>> (32 - n))) & 0xFFFFFFFF;

int _rotl8(int v, int n) => ((v << n) | (v >> (8 - n))) & 0xFF;

int _xtime(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? 0x11b : 0)) & 0xFF;

int _mul(int a, int b) {
  var r = 0;
  while (b != 0) {
    if ((b & 1) != 0) r ^= a;
    a = _xtime(a);
    b >>= 1;
  }
  return r;
}

void _initTables() {
  if (_tablesReady) return;
  // S-box through the multiplicative inverse in GF(2^8) + affine transform.
  var p = 1, q = 1;
  do {
    p = p ^ ((p << 1) & 0xFF) ^ ((p & 0x80) != 0 ? 0x1B : 0);
    q ^= q << 1;
    q ^= q << 2;
    q ^= q << 4;
    q &= 0xFF;
    if ((q & 0x80) != 0) q ^= 0x09;
    final x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4);
    _sbox[p] = (x ^ 0x63) & 0xFF;
  } while (p != 1);
  _sbox[0] = 0x63;
  for (var i = 0; i < 256; i++) {
    _invSbox[_sbox[i]] = i;
  }
  for (var i = 0; i < 256; i++) {
    final s = _sbox[i];
    final e = _mul(s, 2) | (s << 8) | (s << 16) | (_mul(s, 3) << 24);
    _te0[i] = e;
    _te1[i] = _rotl32(e, 8);
    _te2[i] = _rotl32(e, 16);
    _te3[i] = _rotl32(e, 24);
    final si = _invSbox[i];
    final d = _mul(si, 14) |
        (_mul(si, 9) << 8) |
        (_mul(si, 13) << 16) |
        (_mul(si, 11) << 24);
    _td0[i] = d;
    _td1[i] = _rotl32(d, 8);
    _td2[i] = _rotl32(d, 16);
    _td3[i] = _rotl32(d, 24);
  }
  _tablesReady = true;
}

int _subWord(int w) =>
    _sbox[w & 0xFF] |
    (_sbox[(w >>> 8) & 0xFF] << 8) |
    (_sbox[(w >>> 16) & 0xFF] << 16) |
    (_sbox[(w >>> 24) & 0xFF] << 24);

/// AES-256 block cipher. Construct once per key; [encryptBlock] and
/// [decryptBlock] work on 4-word blocks of a `Uint32List` (little-endian
/// packing) and may be used in place (`src`/`si` equal to `dst`/`di`).
final class Aes256 {
  Aes256(Uint8List key32) : _ek = Uint32List(_rkWords) {
    if (key32.length != 32) {
      throw ArgumentError.value(key32.length, 'key32.length', 'must be 32');
    }
    _initTables();
    final kw = Uint8List.fromList(key32).buffer.asUint32List();
    for (var i = 0; i < 8; i++) {
      _ek[i] = kw[i];
    }
    var rcon = 1;
    for (var i = 8; i < _rkWords; i++) {
      var tmp = _ek[i - 1];
      if (i % 8 == 0) {
        tmp = _subWord(((tmp >>> 8) | (tmp << 24)) & 0xFFFFFFFF) ^ rcon;
        rcon = _xtime(rcon);
      } else if (i % 8 == 4) {
        tmp = _subWord(tmp);
      }
      _ek[i] = _ek[i - 8] ^ tmp;
    }
  }

  final Uint32List _ek;
  Uint32List? _dkCache;

  /// Equivalent inverse cipher key schedule (built on first decrypt).
  Uint32List get _dk {
    final c = _dkCache;
    if (c != null) return c;
    final dk = Uint32List(_rkWords);
    for (var r = 0; r <= _nr; r++) {
      for (var j = 0; j < 4; j++) {
        var w = _ek[4 * (_nr - r) + j];
        if (r != 0 && r != _nr) {
          w = _td0[_sbox[w & 0xFF]] ^
              _td1[_sbox[(w >>> 8) & 0xFF]] ^
              _td2[_sbox[(w >>> 16) & 0xFF]] ^
              _td3[_sbox[w >>> 24]];
        }
        dk[4 * r + j] = w;
      }
    }
    return _dkCache = dk;
  }

  /// Encrypts one block: words `src[si..si+3]` -> `dst[di..di+3]`.
  void encryptBlock(Uint32List src, int si, Uint32List dst, int di) {
    final rk = _ek;
    final te0 = _te0, te1 = _te1, te2 = _te2, te3 = _te3;
    var s0 = src[si] ^ rk[0];
    var s1 = src[si + 1] ^ rk[1];
    var s2 = src[si + 2] ^ rk[2];
    var s3 = src[si + 3] ^ rk[3];
    var k = 4;
    for (var r = 1; r < _nr; r++) {
      final t0 = te0[s0 & 0xFF] ^
          te1[(s1 >>> 8) & 0xFF] ^
          te2[(s2 >>> 16) & 0xFF] ^
          te3[s3 >>> 24] ^
          rk[k];
      final t1 = te0[s1 & 0xFF] ^
          te1[(s2 >>> 8) & 0xFF] ^
          te2[(s3 >>> 16) & 0xFF] ^
          te3[s0 >>> 24] ^
          rk[k + 1];
      final t2 = te0[s2 & 0xFF] ^
          te1[(s3 >>> 8) & 0xFF] ^
          te2[(s0 >>> 16) & 0xFF] ^
          te3[s1 >>> 24] ^
          rk[k + 2];
      final t3 = te0[s3 & 0xFF] ^
          te1[(s0 >>> 8) & 0xFF] ^
          te2[(s1 >>> 16) & 0xFF] ^
          te3[s2 >>> 24] ^
          rk[k + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
      k += 4;
    }
    final sb = _sbox;
    dst[di] = (sb[s0 & 0xFF] |
            (sb[(s1 >>> 8) & 0xFF] << 8) |
            (sb[(s2 >>> 16) & 0xFF] << 16) |
            (sb[s3 >>> 24] << 24)) ^
        rk[k];
    dst[di + 1] = (sb[s1 & 0xFF] |
            (sb[(s2 >>> 8) & 0xFF] << 8) |
            (sb[(s3 >>> 16) & 0xFF] << 16) |
            (sb[s0 >>> 24] << 24)) ^
        rk[k + 1];
    dst[di + 2] = (sb[s2 & 0xFF] |
            (sb[(s3 >>> 8) & 0xFF] << 8) |
            (sb[(s0 >>> 16) & 0xFF] << 16) |
            (sb[s1 >>> 24] << 24)) ^
        rk[k + 2];
    dst[di + 3] = (sb[s3 & 0xFF] |
            (sb[(s0 >>> 8) & 0xFF] << 8) |
            (sb[(s1 >>> 16) & 0xFF] << 16) |
            (sb[s2 >>> 24] << 24)) ^
        rk[k + 3];
  }

  /// Decrypts one block: words `src[si..si+3]` -> `dst[di..di+3]`.
  void decryptBlock(Uint32List src, int si, Uint32List dst, int di) {
    final rk = _dk;
    final td0 = _td0, td1 = _td1, td2 = _td2, td3 = _td3;
    var s0 = src[si] ^ rk[0];
    var s1 = src[si + 1] ^ rk[1];
    var s2 = src[si + 2] ^ rk[2];
    var s3 = src[si + 3] ^ rk[3];
    var k = 4;
    for (var r = 1; r < _nr; r++) {
      final t0 = td0[s0 & 0xFF] ^
          td1[(s3 >>> 8) & 0xFF] ^
          td2[(s2 >>> 16) & 0xFF] ^
          td3[s1 >>> 24] ^
          rk[k];
      final t1 = td0[s1 & 0xFF] ^
          td1[(s0 >>> 8) & 0xFF] ^
          td2[(s3 >>> 16) & 0xFF] ^
          td3[s2 >>> 24] ^
          rk[k + 1];
      final t2 = td0[s2 & 0xFF] ^
          td1[(s1 >>> 8) & 0xFF] ^
          td2[(s0 >>> 16) & 0xFF] ^
          td3[s3 >>> 24] ^
          rk[k + 2];
      final t3 = td0[s3 & 0xFF] ^
          td1[(s2 >>> 8) & 0xFF] ^
          td2[(s1 >>> 16) & 0xFF] ^
          td3[s0 >>> 24] ^
          rk[k + 3];
      s0 = t0;
      s1 = t1;
      s2 = t2;
      s3 = t3;
      k += 4;
    }
    final sb = _invSbox;
    dst[di] = (sb[s0 & 0xFF] |
            (sb[(s3 >>> 8) & 0xFF] << 8) |
            (sb[(s2 >>> 16) & 0xFF] << 16) |
            (sb[s1 >>> 24] << 24)) ^
        rk[k];
    dst[di + 1] = (sb[s1 & 0xFF] |
            (sb[(s0 >>> 8) & 0xFF] << 8) |
            (sb[(s3 >>> 16) & 0xFF] << 16) |
            (sb[s2 >>> 24] << 24)) ^
        rk[k + 1];
    dst[di + 2] = (sb[s2 & 0xFF] |
            (sb[(s1 >>> 8) & 0xFF] << 8) |
            (sb[(s0 >>> 16) & 0xFF] << 16) |
            (sb[s3 >>> 24] << 24)) ^
        rk[k + 2];
    dst[di + 3] = (sb[s3 & 0xFF] |
            (sb[(s2 >>> 8) & 0xFF] << 8) |
            (sb[(s1 >>> 16) & 0xFF] << 16) |
            (sb[s0 >>> 24] << 24)) ^
        rk[k + 3];
  }

  /// Convenience for tests: encrypts one 16-byte block, returns a new list.
  Uint8List encryptBlockBytes(Uint8List block16) =>
      _viaWords(block16, encryptBlock);

  /// Convenience for tests: decrypts one 16-byte block, returns a new list.
  Uint8List decryptBlockBytes(Uint8List block16) =>
      _viaWords(block16, decryptBlock);

  Uint8List _viaWords(
      Uint8List b, void Function(Uint32List, int, Uint32List, int) f) {
    if (b.length != 16) {
      throw ArgumentError.value(b.length, 'block.length', 'must be 16');
    }
    final io = Uint8List.fromList(b);
    final w = io.buffer.asUint32List();
    f(w, 0, w, 0);
    return io;
  }

  /// Zeroes the key schedules (best-effort hygiene; the object is unusable
  /// afterwards).
  void wipe() {
    _ek.fillRange(0, _ek.length, 0);
    _dkCache?.fillRange(0, _rkWords, 0);
  }
}
