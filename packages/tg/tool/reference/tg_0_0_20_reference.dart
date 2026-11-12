// REFERENCE COPY of the transport/crypto code of tg 0.0.20 (MIT, (c) Mahdi K.
// Fard), copied verbatim from the unmodified sources and renamed `ref*`.
//
// Purpose: an independent, frozen oracle for golden tests and benchmarks while
// the real code under lib/src is optimized. DO NOT OPTIMIZE OR "FIX" ANYTHING
// HERE (including the quirks: Int64 views ignoring view offsets, constant RNG
// is handled by the caller, no msg_key verification).
//
// Only mechanical changes versus upstream: names (ref*/Ref*), the private
// types `_IdSeq`/`AuthorizationKey` replaced by `RefIdSeq`/`RefAuthKey`, and
// `Obfuscation`/`_Frame`/transformers made library-public so tests can use them.
//
// Sources: encrypt.dart (AesEcb), crypto.dart (sha256), private.dart
// (_aesIgeEncryptDecrypt, _encryptDecryptMessage), obfuscation.dart (AesCtr,
// Obfuscation.preamble), encoders.dart (_encodeWithAuthPadded, _encodeNoAuth),
// frame.dart (_Frame.parse), decoders.dart (both transformers), extensions.dart
// (_XInt, _List.reverse).
// ignore_for_file: unused_element

import 'dart:async';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;
import 'package:t/t.dart';

// ---------------------------------------------------------------------------
// crypto.dart
// ---------------------------------------------------------------------------

List<int> refSha256(List<int> data) {
  return pc.SHA256Digest().process(Uint8List.fromList(data));
}

// ---------------------------------------------------------------------------
// extensions.dart
// ---------------------------------------------------------------------------

extension _RefList<T> on List<T> {
  void reverse(int start, int length) {
    final rev = sublist(start, start + length).reversed.toList();
    setRange(start, start + length, rev);
  }
}

extension _RefXInt on int {
  Uint8List asUint64List([bool littleEndian = true]) {
    final b = Uint8List(8);
    b.buffer
        .asByteData()
        .setUint64(0, this, littleEndian ? Endian.little : Endian.big);

    return b;
  }

  Uint8List asUint32List([bool littleEndian = true]) {
    final b = Uint8List(4);
    b.buffer
        .asByteData()
        .setUint32(0, this, littleEndian ? Endian.little : Endian.big);

    return b;
  }
}

extension _RefXObject on TlObject {
  Uint8List asUint8List() {
    final buffer = <int>[];
    serialize(buffer);

    return Uint8List.fromList(buffer);
  }
}

// ---------------------------------------------------------------------------
// encrypt.dart
// ---------------------------------------------------------------------------

/// Wraps the AES Algorithm.
class RefAesEcb {
  final RefKey key;
  final pc.BlockCipher _cipher;

  RefAesEcb(this.key) : _cipher = pc.BlockCipher('AES/ECB');

  RefEncrypted encrypt(Uint8List bytes) {
    _cipher
      ..reset()
      ..init(true, pc.KeyParameter(key.bytes));

    return RefEncrypted(_processBlocks(bytes));
  }

  Uint8List decrypt(RefEncrypted encrypted) {
    _cipher
      ..reset()
      ..init(false, pc.KeyParameter(key.bytes));

    return _processBlocks(encrypted.bytes);
  }

  void encrypt2(
    Uint8List input,
    int inputOffset,
    int inputCount,
    Uint8List output,
    int outputOffset,
  ) {
    final inn = input.skip(inputOffset).take(inputCount).toList();
    final enc = encrypt(Uint8List.fromList(inn));

    output.setRange(outputOffset, outputOffset + enc.bytes.length, enc.bytes);
  }

  void decrypt2(
    Uint8List input,
    int inputOffset,
    int inputCount,
    Uint8List output,
    int outputOffset,
  ) {
    final inn = input.skip(inputOffset).take(inputCount).toList();
    final enc = decrypt(RefEncrypted(Uint8List.fromList(inn)));

    output.setRange(outputOffset, outputOffset + enc.length, enc);
  }

  Uint8List _processBlocks(Uint8List input) {
    var output = Uint8List(input.lengthInBytes);

    for (int offset = 0; offset < input.lengthInBytes;) {
      offset += _cipher.processBlock(input, offset, output, offset);
    }

    return output;
  }
}

/// Represents an encripted value.
class RefEncrypted {
  /// Creates an Encrypted object from a Uint8List.
  const RefEncrypted(this.bytes);

  /// Gets the Encrypted bytes.
  final Uint8List bytes;
}

/// Represents an Encryption Key.
class RefKey extends RefEncrypted {
  /// Creates an Encryption Key object from a Uint8List.
  RefKey(Uint8List bytes) : super(bytes);

  int get length => bytes.lengthInBytes;
}

// ---------------------------------------------------------------------------
// dh.dart (AesKeyIV) and auth_key.dart / encoders.dart (_IdSeq)
// ---------------------------------------------------------------------------

class RefAesKeyIV {
  const RefAesKeyIV(this.key, this.iv);

  final Uint8List key;
  final Uint8List iv;
}

/// Stand-in for the fields of `AuthorizationKey` used by the original code.
class RefAuthKey {
  const RefAuthKey(this.id, this.key, this.salt);

  final int id;
  final List<int> key;
  final int salt;
}

class RefIdSeq {
  const RefIdSeq(this.id, this.seqno);
  final int id;
  final int seqno;
}

// ---------------------------------------------------------------------------
// private.dart
// ---------------------------------------------------------------------------

Uint8List refAesIgeEncryptDecrypt(
  Uint8List input,
  RefAesKeyIV keys,
  bool encrypt,
) {
  assert(input.length % 16 == 0, 'AES_IGE input size not divisible by 16.');
  final aes = RefAesEcb(RefKey(keys.key));

  final output = Uint8List(input.length);
  final prevBytes = Uint8List.fromList(keys.iv);
  final span = input.buffer.asInt64List();
  final sout = output.buffer.asInt64List();
  final prev = prevBytes.buffer.asInt64List();

  if (!encrypt) {
    {
      final temp = prev[2];
      prev[2] = prev[0];
      prev[0] = temp;
    }

    {
      final temp = prev[3];
      prev[3] = prev[1];
      prev[1] = temp;
    }
  }

  if (encrypt) {
    for (int i = 0, count = input.length ~/ 8; i < count;) {
      sout[i] = span[i] ^ prev[0];
      sout[i + 1] = span[i + 1] ^ prev[1];
      aes.encrypt2(output, i * 8, 16, output, i * 8);
      prev[0] = sout[i] ^= prev[2];
      prev[1] = sout[i + 1] ^= prev[3];
      prev[2] = span[i++];
      prev[3] = span[i++];
    }
  } else {
    for (int i = 0, count = input.length ~/ 8; i < count;) {
      sout[i] = span[i] ^ prev[0];
      sout[i + 1] = span[i + 1] ^ prev[1];
      aes.decrypt2(output, i * 8, 16, output, i * 8);
      prev[0] = sout[i] ^= prev[2];
      prev[1] = sout[i + 1] ^= prev[3];
      prev[2] = span[i++];
      prev[3] = span[i++];
    }
  }

  return output;
}

Uint8List refEncryptDecryptMessage(
  Uint8List input,
  bool encrypt,
  int x,
  List<int> authKey,
  Uint8List msgKey,
  int msgKeyOffset,
) {
  final x1 = [
    ...msgKey.skip(msgKeyOffset).take(16),
    ...authKey.skip(x).take(36),
  ];
  final x2 = [
    ...authKey.skip(40 + x).take(36),
    ...msgKey.skip(msgKeyOffset).take(16),
  ];

  final sha256A = refSha256(x1);
  final sha256B = refSha256(x2);

  final aesKey = [
    ...sha256A.skip(0).take(8),
    ...sha256B.skip(8).take(16),
    ...sha256A.skip(24).take(8),
  ];

  final aesIV = [
    ...sha256B.skip(0).take(8),
    ...sha256A.skip(8).take(16),
    ...sha256B.skip(24).take(8),
  ];

  final r = refAesIgeEncryptDecrypt(
    input,
    RefAesKeyIV(Uint8List.fromList(aesKey), Uint8List.fromList(aesIV)),
    encrypt,
  );

  return r;
}

// ---------------------------------------------------------------------------
// obfuscation.dart
// ---------------------------------------------------------------------------

class RefAesCtr {
  late final pc.StreamCipher _cipher;

  RefAesCtr(Uint8List key, Uint8List iv) {
    final params = pc.ParametersWithIV(pc.KeyParameter(key), iv);
    _cipher = pc.StreamCipher('AES/CTR')..init(true, params);
  }
  void encryptDecrypt(List<int> input, int length) {
    assert(length <= input.length);

    final copy = Uint8List.fromList(input);
    final processed = _cipher.process(copy);

    for (int i = 0; i < length; i++) {
      input[i] = processed[i];
    }
  }
}

/// Obfuscation (from a pre-computed preamble; `Obfuscation.random` is just
/// `preamble` with `_rng.getBytes(58 bytes)`).
class RefObfuscation {
  const RefObfuscation._(this.send, this.recv, this.preamble);

  /// Generate an obfuscator from a pre-computed preamble.
  ///
  /// [random] Must be 58 bytes random.
  factory RefObfuscation.preamble(Uint8List random, bool padded, int dcId,
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
          refSha256([...sendKey.sublist(0, 32), ...sec.sublist(0, 16)]));

      recvKey = Uint8List.fromList(
          refSha256([...recvKey.sublist(0, 32), ...sec.sublist(0, 16)]));
    }

    final sendCtr = RefAesCtr(sendKey, sendIV);
    final recvCtr = RefAesCtr(recvKey, recvIV);
    final encrypted = Uint8List.fromList(preamble.toList());

    sendCtr.encryptDecrypt(encrypted, 64);

    for (int i = 56; i < 64; i++) {
      preamble[i] = encrypted[i];
    }

    return RefObfuscation._(sendCtr, recvCtr, preamble);
  }

  /// Sender encryption.
  final RefAesCtr send;

  /// Receiver encryption.
  final RefAesCtr recv;

  /// Preamble used to generate [send] and [recv].
  final Uint8List preamble;
}

// ---------------------------------------------------------------------------
// encoders.dart
// ---------------------------------------------------------------------------

Uint8List refEncodeNoAuth(
  TlObject message,
  RefIdSeq m,
) {
  final messageBuffer = message.asUint8List();
  final buffer = <int>[
    ...(messageBuffer.length + 20).asUint32List(),
    ...0.asUint64List(),
    ...m.id.asUint64List(),
    ...messageBuffer.length.asUint32List(),
    ...messageBuffer,
  ];

  return Uint8List.fromList(buffer);
}

Uint8List refEncodeWithAuthPadded(
  TlObject message,
  RefIdSeq m,
  int sessionId,
  RefAuthKey auth,
  Uint8List paddingData,
) {
  final messageBuffer = message.asUint8List();

  final clear = <int>[
    ...auth.key.skip(88).take(32),
    ...auth.salt.asUint64List(),
    ...sessionId.asUint64List(),
    ...m.id.asUint64List(),
    ...m.seqno.asUint32List(),
    ...messageBuffer.length.asUint32List(),
    ...messageBuffer,
    ...paddingData,
  ];

  final msgKey = Uint8List.fromList(refSha256(clear));
  final encryptedData = refEncryptDecryptMessage(
    Uint8List.fromList(clear.skip(32).toList()),
    true,
    0,
    auth.key,
    msgKey,
    8,
  );

  final writerLength = 8 + 16 + encryptedData.length;

  final buffer = [
    ...writerLength.asUint32List(),
    ...auth.id.asUint64List(),
    ...msgKey.skip(8).take(16),
    ...encryptedData,
  ];

  return Uint8List.fromList(buffer);
}

// ---------------------------------------------------------------------------
// frame.dart (decrypt/parse part of _Frame.parse)
// ---------------------------------------------------------------------------

class RefFrame {
  const RefFrame(
    this.message,
    this.messageId,
    this.authKeyId,
    this.seqno,
  );

  /// Parse from [Uint8List].
  factory RefFrame.parse(
    Uint8List data,
    RefObfuscation? obfuscation,
    List<int> authKey,
  ) {
    obfuscation?.recv.encryptDecrypt(data, data.length);

    final br = BinaryReader(data);

    final authKeyId = br.readInt64();

    if (authKeyId == 0) {
      final messageId = br.readInt64();
      final msgLength = br.readInt32(); // Message Length.

      final messageBuffer = br.readRawBytes(msgLength);
      final br2 = BinaryReader(messageBuffer);
      final message = br2.readObject();

      return RefFrame(message, messageId, authKeyId, null);
    }

    //

    final decryptedData = refEncryptDecryptMessage(
      Uint8List.fromList(data.skip(24).toList()),
      false,
      8,
      authKey,
      data,
      8,
    );

    final reader = BinaryReader(decryptedData);

    {
      final serverSalt = reader.readInt64(); // int64 salt
      final _ = serverSalt;
    }

    {
      final sessionId = reader.readInt64(); // int64 session_id
      final _ = sessionId;
    }

    final msgId = reader.readInt64(); // int64 message_id
    final seqno = reader.readInt32(); // int32 msg_seqno

    {
      final length = reader.readInt32(); // int32 message_data_length
      final _ = length;
    }

    final message = reader.readObject();

    return RefFrame(message, msgId, authKeyId, seqno);
  }

  final TlObject message;
  final int messageId;
  final int authKeyId;
  final int? seqno;

  Uint8List toUint8List(RefObfuscation? obfuscation) {
    final messageBuffer = message.asUint8List();

    final data = <int>[
      ...(messageBuffer.length + 20).asUint32List(),
      ...authKeyId.asUint64List(),
      ...messageId.asUint64List(),
      ...messageBuffer.length.asUint32List(),
      ...messageBuffer,
    ];

    obfuscation?.send.encryptDecrypt(data, data.length);

    return Uint8List.fromList(data);
  }
}

// ---------------------------------------------------------------------------
// decoders.dart
// ---------------------------------------------------------------------------

class RefEncryptedTransformer {
  RefEncryptedTransformer(
    this._receiver,
    this._obfuscation,
    this._authKey,
    this._msgsToAck,
  ) {
    _receiver.listen(_readFrame);
  }

  final _streamController = StreamController<TlObject>.broadcast();
  Stream<TlObject> get stream => _streamController.stream;

  final Stream<List<int>> _receiver;
  final RefObfuscation _obfuscation;
  final List<int> _authKey;
  final Set<int> _msgsToAck;

  final List<int> _read = [];
  int? _length;

  void _readFrame(List<int> l) {
    _read.addAll(l);

    while (true) {
      if (_length == null && _read.length >= 4) {
        final temp = _read.take(4).toList();
        _obfuscation.recv.encryptDecrypt(temp, 4);
        _length = ByteData.sublistView(Uint8List.fromList(temp))
            .getInt32(0, Endian.little);
      }

      final length = _length;
      if (length == null || _read.length < length + 4) break;

      final buffer = Uint8List.fromList(_read.skip(4).take(length).toList());
      _read.removeRange(0, length + 4);
      _length = null;

      final frame = RefFrame.parse(
        buffer,
        _obfuscation,
        _authKey,
      );

      final seqno = frame.seqno;

      if (seqno != null && (seqno & 1) != 0) {
        _msgsToAck.add(frame.messageId);
      }

      _streamController.add(frame.message);
    }
  }
}

class RefUnEncryptedTransformer {
  RefUnEncryptedTransformer(
    this._receiver,
    this._msgsToAck,
    this._obfuscation,
  ) {
    _subscription = _receiver.listen(_readFrame);
  }

  StreamSubscription<List<int>>? _subscription;

  Future<void> dispose() async {
    await _subscription?.cancel();
  }

  final _streamController = StreamController<TlObject>.broadcast();
  Stream<TlObject> get stream => _streamController.stream;

  final Stream<List<int>> _receiver;
  final RefObfuscation? _obfuscation;
  final Set<int> _msgsToAck;
  final List<int> _read = [];
  int? _length;

  void _readFrame(List<int> l) {
    _read.addAll(l);
    while (true) {
      if (_length == null && _read.length >= 4) {
        final temp = _read.take(4).toList();
        _obfuscation?.recv.encryptDecrypt(temp, 4);

        _length = ByteData.sublistView(Uint8List.fromList(temp))
            .getInt32(0, Endian.little);
      }

      final length = _length;
      if (length == null || _read.length < length + 4) break;

      final buffer = Uint8List.fromList(_read.skip(4).take(length).toList());
      _read.removeRange(0, length + 4);
      _length = null;

      final frame = RefFrame.parse(buffer, _obfuscation, []);
      final seqno = frame.seqno;

      if (seqno != null && (seqno & 1) != 0) {
        _msgsToAck.add(frame.messageId);
      }

      _streamController.add(frame.message);
    }
  }
}
