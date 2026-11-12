part of '../tg.dart';

/// Bytes the serialized [message] is expected to need beyond a small header
/// (TeleVault): avoids growing the sink for upload parts.
int _serializedSizeHint(TlObject message) {
  if (message is UploadSaveFilePart) return message.bytes.length + 64;
  if (message is UploadSaveBigFilePart) return message.bytes.length + 64;
  return 256;
}

/// Plain transport frame: u32 len(+20) | u64 authKeyId | u64 msgId | u32 len |
/// message, built in one Uint8List (TeleVault).
Uint8List _plainFrame(TlObject message, int authKeyId, int messageId) {
  final sink = ByteSink(24 + _serializedSizeHint(message));
  sink.length = 24;
  message.serialize(sink);
  final data = sink.takeBytes();
  final msgLen = data.length - 24;
  ByteData.sublistView(data)
    ..setUint32(0, msgLen + 20, Endian.little)
    ..setUint64(4, authKeyId, Endian.little)
    ..setUint64(12, messageId, Endian.little)
    ..setUint32(20, msgLen, Endian.little);
  return data;
}

Uint8List _encodeNoAuth(
  TlObject message,
  _IdSeq m,
) {
  return _plainFrame(message, 0, m.id);
}

Uint8List _encodeWithAuth(
  TlObject message,
  _IdSeq m,
  int sessionId,
  AuthorizationKey auth,
) {
  return _encodeWithAuthImpl(message, m, sessionId, auth, null);
}

/// Same as [_encodeWithAuth] but with the padding bytes supplied by the caller
/// (TeleVault: allows deterministic golden tests).
Uint8List _encodeWithAuthPadded(
  TlObject message,
  _IdSeq m,
  int sessionId,
  AuthorizationKey auth,
  Uint8List paddingData,
) {
  return _encodeWithAuthImpl(message, m, sessionId, auth, paddingData);
}

/// Encrypted frame built in ONE buffer (TeleVault).
///
/// Buffer layout while encoding (clear = what the msg_key hashes):
///   [0, 32)   authKey[88:120]
///   [32, 64)  salt | session_id | msg_id | seqno | length
///   [64, ..)  message | padding
/// After sha256(clear) the frame header is written over [4, 32):
///   u32 LE (8 + 16 + encLen) | authKeyId | msgKey
/// and clear[32:] is IGE-encrypted in place, so the frame is the view
/// starting at offset 4 (IGE data at frame offset 28). [0, 4) is zeroed.
///
/// [paddingData] null = random padding:
/// `((0x7FFFFFF0 - (len + 32)) % 16) + (2 + rnd(14)) * 16` bytes.
Uint8List _encodeWithAuthImpl(
  TlObject message,
  _IdSeq m,
  int sessionId,
  AuthorizationKey auth,
  Uint8List? paddingData,
) {
  final sink = ByteSink(64 + _serializedSizeHint(message) + 256);
  sink.length = 64;
  message.serialize(sink);
  final msgLen = sink.length - 64;
  final padLen = paddingData?.length ??
      ((0x7FFFFFF0 - (msgLen + 32)) % 16) + ((2 + _rng.nextInt(14)) * 16);
  final clearEnd = 64 + msgLen + padLen;
  sink.length = clearEnd;
  final buf = sink.takeBytes();

  if (paddingData != null) {
    buf.setRange(64 + msgLen, clearEnd, paddingData);
  } else {
    _rng.getBytes(buf, 64 + msgLen, padLen);
  }

  final authKey = auth._keyBytes;
  buf.setRange(0, 32, authKey, 88);
  ByteData.sublistView(buf)
    ..setUint64(32, auth.salt, Endian.little)
    ..setUint64(40, sessionId, Endian.little)
    ..setUint64(48, m.id, Endian.little)
    ..setUint32(56, m.seqno, Endian.little)
    ..setUint32(60, msgLen, Endian.little);

  final backend = TgCrypto.backend;
  final sha = Uint8List(32);
  backend.sha256(buf, 0, clearEnd, sha, 0);

  final encLen = clearEnd - 32;
  ByteData.sublistView(buf)
    ..setUint32(4, 8 + 16 + encLen, Endian.little)
    ..setUint64(8, auth.id, Endian.little);
  buf.setRange(16, 32, sha, 8);
  buf.fillRange(0, 4, 0);

  _cryptMessageInPlace(
    buf,
    32,
    encLen,
    encrypt: true,
    x: 0,
    authKey: authKey,
    msgKey: sha,
    msgKeyOffset: 8,
  );

  return Uint8List.sublistView(buf, 4, clearEnd);
}

class MessageIdGenerator {
  int _lastSentMessageId = 0;
  int _seqno = 0;
  int serverTicksOffset = 0;

  _IdSeq _next(bool preferEncryption) {
    var msgId =
        DateTime.now().toUtc().ticks + serverTicksOffset - 621355968000000000;
    msgId = msgId * 428 +
        (msgId >> 24) *
            25110956; // approximately unixtime*2^32 and divisible by 4

    if (msgId <= _lastSentMessageId) {
      msgId = _lastSentMessageId += 4;
    } else {
      _lastSentMessageId = msgId;
    }

    final seqno = preferEncryption ? _seqno++ * 2 + 1 : _seqno * 2;

    return _IdSeq(msgId, seqno);
  }
}

class _IdSeq {
  const _IdSeq(this.id, this.seqno);
  final int id;
  final int seqno;
}
