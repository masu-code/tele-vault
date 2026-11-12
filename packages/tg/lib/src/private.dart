part of '../tg.dart';

// TeleVault: was `Random()` and `getBytes` filled `(i + 1) % 256`, so DH
// nonces/exponent, RSA padding, the obfuscation preamble and MTProto padding
// were constant. Must stay a CSPRNG.
final _rng = Random.secure();

Uint8List _int64ToBigEndian(int value) {
  int i = 1;
  for (int temp = value; (temp >>= 8) != 0;) {
    i++;
  }

  final result = Uint8List(i);
  for (; --i >= 0; value >>= 8) {
    result[i] = value % 256;
  }

  return result;
}

String _hex(Iterable<int> v) {
  final h = v
      .map((vv) => vv.toRadixString(16).padLeft(2, '0'))
      .join('')
      .toUpperCase();

  return h;
}

BigInt _bigEndianInteger(Iterable<int> value) {
  final data = _hex(value);
  return BigInt.parse(data, radix: 16);
}

Uint8List _fromHexToUint8List(String value) {
  if (value.length.isOdd) {
    value = '0$value';
  }

  final r = Uint8List(value.length ~/ 2);

  for (int i = 0; i < value.length ~/ 2; i += 1) {
    final sub = value.substring(i * 2, i * 2 + 2);
    r[i] = int.parse(sub, radix: 16);
  }

  return r;
}

Uint8List _aesIgeEncryptDecrypt(
  Uint8List input,
  AesKeyIV keys,
  bool encrypt,
) {
  assert(input.length % 16 == 0, 'AES_IGE input size not divisible by 16.');
  // TeleVault: delegates to the crypto backend (one key schedule per call,
  // views supported). The original read `input.buffer` as Int64 words and
  // ignored view offsets.
  final output = Uint8List(input.length);
  TgCrypto.backend.aesIge(
    encrypt: encrypt,
    key32: keys.key,
    iv32: keys.iv,
    input: input,
    inOffset: 0,
    length: input.length,
    output: output,
    outOffset: 0,
  );
  return output;
}

/// MTProto 2.0 AES key and IV from a message key (TeleVault).
///
/// x1 = msgKey[o:o+16] || authKey[x:x+36]; x2 = authKey[40+x:76+x] || msgKey;
/// A = sha256(x1), B = sha256(x2); key = A[0:8] || B[8:24] || A[24:32];
/// iv = B[0:8] || A[8:24] || B[24:32]. x = 0 for client->server, 8 for
/// server->client.
AesKeyIV _messageKeyIv(
  Uint8List authKey,
  int x,
  Uint8List msgKey,
  int msgKeyOffset,
) {
  final backend = TgCrypto.backend;
  // x1 at [0, 52), x2 at [52, 104), A at [104, 136), B at [136, 168).
  final s = Uint8List(168);
  s.setRange(0, 16, msgKey, msgKeyOffset);
  s.setRange(16, 52, authKey, x);
  s.setRange(52, 88, authKey, 40 + x);
  s.setRange(88, 104, msgKey, msgKeyOffset);
  backend.sha256(s, 0, 52, s, 104);
  backend.sha256(s, 52, 52, s, 136);

  final key = Uint8List(32)
    ..setRange(0, 8, s, 104)
    ..setRange(8, 24, s, 144)
    ..setRange(24, 32, s, 128);
  final iv = Uint8List(32)
    ..setRange(0, 8, s, 136)
    ..setRange(8, 24, s, 112)
    ..setRange(24, 32, s, 160);
  s.fillRange(0, s.length, 0);
  return AesKeyIV(key, iv);
}

Uint8List _asBytes(List<int> v) => v is Uint8List ? v : Uint8List.fromList(v);

/// In-place MTProto 2.0 message encryption/decryption of
/// `data[offset .. offset+length)` (TeleVault).
void _cryptMessageInPlace(
  Uint8List data,
  int offset,
  int length, {
  required bool encrypt,
  required int x,
  required Uint8List authKey,
  required Uint8List msgKey,
  required int msgKeyOffset,
}) {
  final keys = _messageKeyIv(authKey, x, msgKey, msgKeyOffset);
  try {
    TgCrypto.backend.aesIge(
      encrypt: encrypt,
      key32: keys.key,
      iv32: keys.iv,
      input: data,
      inOffset: offset,
      length: length,
      output: data,
      outOffset: offset,
    );
  } finally {
    keys.key.fillRange(0, 32, 0);
    keys.iv.fillRange(0, 32, 0);
  }
}

AesKeyIV _constructTmpAESKeyIV(Int128 serverNonce, Int256 newNonce) {
  final x1 = sha1([...newNonce.data, ...serverNonce.data]);
  final x2 = sha1([...serverNonce.data, ...newNonce.data]);
  final x3 = sha1([...newNonce.data, ...newNonce.data]);

  final key = [...x1, ...x2.take(12)];
  final iv = [...x2.skip(12), ...x3, ...newNonce.data.take(4)];

  return AesKeyIV(
    Uint8List.fromList(key),
    Uint8List.fromList(iv),
  );
}

void _checkGoodPrime(BigInt p, int g) {
  // check that 2^2047 <= p < 2^2048
  if (p.bitLength != 2048) throw Exception("p is not 2048-bit number");
  // check that g generates a cyclic subgroup of prime order (p - 1) / 2, i.e. is a quadratic residue mod p.

  bool switchg() {
    switch (g) {
      case 2:
        return p % _n08 != _n07;

      case 3:
        return p % _n03 != BigInt.two;

      case 4:
        return false;
      case 5:
        final m = (p % _n05);
        return m != BigInt.one && m != _n04;
      case 6:
        final m = (p % _n24);
        return m != _n19 && m != _n23;
      case 7:
        final m = (p % _n07);
        return m != _n03 && m != _n05 && m != _n06;
    }
    return true;
  }

  if (switchg()) {
    throw Exception("Bad prime mod 4g");
  }
  // check whether p is a safe prime (meaning that both p and (p - 1) / 2 are prime)
  if (_safePrimes.contains(p)) {
    return;
  }

  if (!p.isProbablePrime()) {
    Exception("p is not a prime number");
  }

  final v = (p - BigInt.one) ~/ BigInt.two;

  if (!v.isProbablePrime()) {
    throw Exception("(p - 1) / 2 is not a prime number");
  }
  _safePrimes.add(p);
}

void _checkGoodGaAndGb(BigInt g, BigInt dhPrime) {
  // check that g, g_a and g_b are greater than 1 and less than dh_prime - 1.
  // We recommend checking that g_a and g_b are between 2^{2048-64} and dh_prime - 2^{2048-64} as well.
  if (g.bitLength < 2048 - 64 || (dhPrime - g).bitLength < 2048 - 64) {
    throw Exception(
        'g^a or g^b is not between 2^{2048-64} and dhPrime - 2^{2048-64}');
  }
}

final List<BigInt> _safePrimes = [
  BigInt.parse(
    '00C71CAEB9C6B1C9048E6C522F70F13F73980D40238E3E21C14934D037563D930F48198A0AA7C14058229493D22530F4DBFA336F6E0AC925139543AED44CCE7C3720FD51F69458705AC68CD4FE6B6B13ABDC9746512969328454F18FAF8C595F642477FE96BB2A941D5BCD1D4AC8CC49880708FA9B378E3C4F3A9060BEE67CF9A4A4A695811051907E162753B56B0F6B410DBA74D8A84B2A14B3144E0EF1284754FD17ED950D5965B4B9DD46582DB1178D169C6BC465B0D6FF9CA3928FEF5B9AE4E418FC15E83EBEA0F87FA9FF5EED70050DED2849F47BF959D956850CE929851F0D8115F635B105EE2E4E15D04B2454BF6F4FADF034B10403119CD8E3B92FCC5B',
    radix: 16,
  ),
];

final _n03 = BigInt.from(3);
final _n04 = BigInt.from(4);
final _n05 = BigInt.from(5);
final _n06 = BigInt.from(6);
final _n07 = BigInt.from(7);
final _n08 = BigInt.from(8);
final _n19 = BigInt.from(19);
final _n23 = BigInt.from(23);
final _n24 = BigInt.from(24);

Uint8List _encryptDecryptMessage(
  Uint8List input,
  bool encrypt,
  int x,
  List<int> authKey,
  Uint8List msgKey,
  int msgKeyOffset,
) {
  // TeleVault: returns a new buffer (as the original); the hot paths use
  // `_cryptMessageInPlace` directly.
  final output = Uint8List.fromList(input);
  _cryptMessageInPlace(
    output,
    0,
    output.length,
    encrypt: encrypt,
    x: x,
    authKey: _asBytes(authKey),
    msgKey: msgKey,
    msgKeyOffset: msgKeyOffset,
  );
  return output;
}
