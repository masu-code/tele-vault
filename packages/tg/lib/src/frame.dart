part of '../tg.dart';

/// TeleVault (T1.4): verify the msg_key and the length/padding of every
/// incoming encrypted frame; offending frames are dropped by the transformer.
const bool kVerifyIncomingMsgKey = true;

/// Thrown by `_Frame.parse` for a frame that must be dropped. [reason] never
/// carries frame bytes (it is logged).
class _FrameDropped implements Exception {
  const _FrameDropped(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Checks `msg_key == sha256(authKey[96:128] || plaintext)[8:24]`, then
/// `32 + msg_len <= plaintext.length` and the MTProto 2.0 padding rule
/// (12..1024 bytes). The decrypted plaintext is `data[24:]`, msg_key is
/// `data[8:24]`.
void _verifyIncomingMsgKey(Uint8List data, Uint8List authKey) {
  final plainLen = data.length - 24;
  final scratch = Uint8List(32 + plainLen);
  try {
    scratch.setRange(0, 32, authKey, 96);
    scratch.setRange(32, scratch.length, data, 24);
    final hash = Uint8List(32);
    TgCrypto.backend.sha256(scratch, 0, scratch.length, hash, 0);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= hash[8 + i] ^ data[8 + i];
    }
    if (diff != 0) throw const _FrameDropped('msg_key mismatch');
  } finally {
    scratch.fillRange(0, scratch.length, 0);
  }

  final msgLen =
      ByteData.sublistView(data, 24 + 28, 24 + 32).getUint32(0, Endian.little);
  if (32 + msgLen > plainLen) throw const _FrameDropped('bad msg_len');
  final padding = plainLen - 32 - msgLen;
  if (padding < 12 || padding > 1024) {
    throw const _FrameDropped('bad padding length');
  }
}

class _Frame {
  const _Frame(
    this.message,
    this.messageId,
    this.authKeyId,
    this.seqno,
  );

  /// Parse from [Uint8List].
  ///
  /// TeleVault: when [expectedAuthKeyId] is set (the encrypted session), a
  /// frame whose auth_key_id differs from it, including a plaintext frame
  /// (auth_key_id 0), is dropped. When [expectedSessionId] is set, a verified
  /// frame whose session_id differs is dropped too. Both checks run after
  /// the CTR pass, so the stream stays in sync.
  factory _Frame.parse(
    Uint8List data,
    Obfuscation? obfuscation,
    List<int> authKey, {
    int? expectedAuthKeyId,
    int? expectedSessionId,
  }) {
    // TeleVault: CTR and IGE run in place on [data]; FastBinaryReader reads
    // views without per-read copies.
    obfuscation?.recv.encryptDecrypt(data, data.length);

    final br = FastBinaryReader(data);

    final authKeyId = br.readInt64();

    if (expectedAuthKeyId != null && authKeyId != expectedAuthKeyId) {
      throw _FrameDropped(
          authKeyId == 0 ? 'unencrypted' : 'foreign auth_key_id');
    }

    if (authKeyId == 0) {
      final messageId = br.readInt64();
      final msgLength = br.readInt32(); // Message Length.

      final messageBuffer = Uint8List.sublistView(data, 20, 20 + msgLength);
      final br2 = FastBinaryReader(messageBuffer);
      final message = br2.readObject();

      return _Frame(message, messageId, authKeyId, null);
    }

    //

    // TeleVault (T1.4): the body must hold a full header and whole AES blocks
    // (IGE would throw otherwise).
    final cipherLen = data.length - 24;
    if (cipherLen < 32 || cipherLen % 16 != 0) {
      throw const _FrameDropped('bad frame length');
    }

    _cryptMessageInPlace(
      data,
      24,
      data.length - 24,
      encrypt: false,
      x: 8,
      authKey: _asBytes(authKey),
      msgKey: data,
      msgKeyOffset: 8,
    );

    if (kVerifyIncomingMsgKey) _verifyIncomingMsgKey(data, _asBytes(authKey));

    final reader = FastBinaryReader(Uint8List.sublistView(data, 24));

    {
      final serverSalt = reader.readInt64(); // int64 salt
      final _ = serverSalt;
    }

    {
      final sessionId = reader.readInt64(); // int64 session_id
      if (expectedSessionId != null && sessionId != expectedSessionId) {
        throw const _FrameDropped('foreign session_id');
      }
    }

    final msgId = reader.readInt64(); // int64 message_id
    final seqno = reader.readInt32(); // int32 msg_seqno

    {
      final length = reader.readInt32(); // int32 message_data_length
      final _ = length;
    }

    final message = reader.readObject();

    /*
      if (decrypted_data.Length < 36) // header below+ctorNb
          throw new WTException($"Decrypted packet too small: {decrypted_data.Length}");
      _sha256Recv.TransformBlock(_dcSession.AuthKey, 96, 32, null, 0);
      _sha256Recv.TransformFinalBlock(decrypted_data, 0, decrypted_data.Length);
      if (!data.AsSpan(8, 16).SequenceEqual(_sha256Recv.Hash.AsSpan(8, 16)))
          throw new WTException("Mismatch between MsgKey & decrypted SHA256");
      */

    return _Frame(message, msgId, authKeyId, seqno);
  }

  final TlObject message;
  final int messageId;
  final int authKeyId;
  final int? seqno;

  Uint8List toUint8List(Obfuscation? obfuscation) {
    final data = _plainFrame(message, authKeyId, messageId);

    obfuscation?.send.encryptDecrypt(data, data.length);

    return data;
  }

  Map<String, dynamic> toJson() {
    return {
      'authKeyId': authKeyId,
      'messageId': messageId,
      'message': message.runtimeType.toString(),
    };
  }

  @override
  String toString() {
    return jsonEncode(toJson());
  }
}
