part of '../tg.dart';

/// Obfuscation.
class Obfuscation {
  const Obfuscation._(this.send, this.recv, this.preamble);

  /// Generate a random obfuscator.
  factory Obfuscation.random(bool padded, int dcId, [Uint8List? secret]) {
    final random = Uint8List(58);

    // TeleVault: real random bytes (Random.secure) and the preamble rules of
    // the MTProto transport obfuscation: the first byte must not be 0xEF
    // (abridged), the first 4 bytes must not look like HTTP ("HEAD", "POST",
    // "GET ", "OPTI"), a TLS record (16 03 01 02) or the intermediate /
    // padded intermediate tags, and bytes 4..8 must not be zero.
    do {
      _rng.getBytes(random);
    } while (!_isValidObfuscationRandom(random));

    return Obfuscation.preamble(random, padded, dcId, secret);
  }

  /// Generate an obfuscator from a pre-computed preamble.
  ///
  /// [random] Must be 58 bytes random.
  factory Obfuscation.preamble(Uint8List random, bool padded, int dcId,
      [Uint8List? secret]) {
    final protocolId = padded ? 0xDD : 0xEE;
    final preamble = Uint8List(64);

    // TODO (xclud): Validate the random buffer.

    preamble.setRange(0, 58, random);

    preamble[62] = preamble[56];
    preamble[63] = preamble[57];

    preamble[56] = preamble[57] = preamble[58] = preamble[59] = protocolId;

    preamble[60] = dcId;
    preamble[61] = dcId >> 8;

    var recvKey = Uint8List.fromList(preamble.sublist(8, 40).toList());
    final recvIV = Uint8List.fromList(preamble.sublist(40, 56).toList());

    preamble.reverse(8, 48);

    var sendKey = Uint8List.fromList(preamble.sublist(8, 40).toList());
    final sendIV = Uint8List.fromList(preamble.sublist(40, 56).toList());

    final sec = secret;
    if (sec != null) {
      sendKey = Uint8List.fromList(
          sha256([...sendKey.sublist(0, 32), ...sec.sublist(0, 16)]));

      recvKey = Uint8List.fromList(
          sha256([...recvKey.sublist(0, 32), ...sec.sublist(0, 16)]));
    }

    final sendCtr = AesCtr(sendKey, sendIV);
    final recvCtr = AesCtr(recvKey, recvIV);
    final encrypted = Uint8List.fromList(preamble.toList());

    sendCtr.encryptDecrypt(encrypted, 64);

    for (int i = 56; i < 64; i++) {
      preamble[i] = encrypted[i];
    }

    return Obfuscation._(sendCtr, recvCtr, preamble);
  }

  /// Sender encryption.
  final AesCtr send;

  /// Receiver encryption.
  final AesCtr recv;

  /// Preamble used to generate [send] and [recv].
  final Uint8List preamble;
}

class AesCtr {
  /// TeleVault: backed by `TgCrypto.backend` (pointycastle only for key sizes
  /// other than 32 bytes, which the transport never uses).
  AesCtr(Uint8List key, Uint8List iv)
      : _stream = key.length == 32 ? TgCrypto.backend.createCtr(key, iv) : null {
    if (_stream == null) {
      final params = pc.ParametersWithIV(pc.KeyParameter(key), iv);
      _cipher = pc.StreamCipher('AES/CTR')..init(true, params);
    }
  }

  final TgCtrStream? _stream;
  pc.StreamCipher? _cipher;

  /// XORs the keystream into `input[0 .. length)`.
  ///
  /// A Uint8List with `length == input.length` (what every call site passes)
  /// is processed in place. Otherwise the original semantics are kept: the
  /// keystream advances by `input.length` and only `length` bytes are written
  /// back.
  void encryptDecrypt(List<int> input, int length) {
    assert(length <= input.length);

    final stream = _stream;
    if (stream != null && input is Uint8List && length == input.length) {
      stream.process(input, 0, length);
      return;
    }

    final copy = Uint8List.fromList(input);
    if (stream != null) {
      stream.process(copy, 0, copy.length);
    } else {
      final processed = _cipher!.process(copy);
      copy.setRange(0, copy.length, processed);
    }

    for (int i = 0; i < length; i++) {
      input[i] = copy[i];
    }
  }
}

/// Transport obfuscation constraints on the first 8 random bytes (TeleVault).
bool _isValidObfuscationRandom(Uint8List random) {
  if (random[0] == 0xEF) return false;
  final bd = ByteData.sublistView(random);
  switch (bd.getUint32(0, Endian.little)) {
    case 0x44414548: // HEAD
    case 0x54534F50: // POST
    case 0x20544547: // GET
    case 0x4954504F: // OPTI
    case 0x02010316: // TLS
    case 0xDDDDDDDD: // padded intermediate
    case 0xEEEEEEEE: // intermediate
      return false;
  }
  return bd.getUint32(4, Endian.little) != 0;
}
