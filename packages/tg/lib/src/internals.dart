part of '../tg.dart';

/// Test/bench hooks into private transport code (TeleVault).
///
/// NOT public API: used only by golden tests and benchmarks. Do not call from
/// application code.
abstract final class TgInternals {
  /// AES-256-IGE over [input] (length must be a multiple of 16).
  static Uint8List aesIge(
    Uint8List input,
    Uint8List key32,
    Uint8List iv32, {
    required bool encrypt,
  }) {
    return _aesIgeEncryptDecrypt(input, AesKeyIV(key32, iv32), encrypt);
  }

  /// MTProto 2.0 message-key based AES-IGE (see `_encryptDecryptMessage`).
  static Uint8List encryptDecryptMessage(
    Uint8List input, {
    required bool encrypt,
    required int x,
    required List<int> authKey,
    required Uint8List msgKey,
    required int msgKeyOffset,
  }) {
    return _encryptDecryptMessage(
      input,
      encrypt,
      x,
      authKey,
      msgKey,
      msgKeyOffset,
    );
  }

  /// Encrypted MTProto frame (without transport obfuscation) with explicit
  /// [padding] bytes.
  static Uint8List encodeWithAuth(
    TlObject m, {
    required int msgId,
    required int seqno,
    required int sessionId,
    required AuthorizationKey auth,
    required Uint8List padding,
  }) {
    return _encodeWithAuthPadded(
      m,
      _IdSeq(msgId, seqno),
      sessionId,
      auth,
      padding,
    );
  }

  /// Encrypted MTProto frame with the production random padding.
  static Uint8List encodeWithAuthRandomPadding(
    TlObject m, {
    required int msgId,
    required int seqno,
    required int sessionId,
    required AuthorizationKey auth,
  }) {
    return _encodeWithAuth(m, _IdSeq(msgId, seqno), sessionId, auth);
  }

  /// Whether 58 random bytes satisfy the obfuscation preamble constraints
  /// enforced by `Obfuscation.random`.
  static bool obfuscationRandomIsValid(Uint8List random58) =>
      _isValidObfuscationRandom(random58);

  /// Unencrypted (auth_key_id = 0) MTProto frame, without obfuscation.
  static Uint8List encodeNoAuth(TlObject m, {required int msgId}) {
    return _encodeNoAuth(m, _IdSeq(msgId, 0));
  }

  /// Parses one transport frame body (the bytes after the 4-byte length).
  /// Applies the receive obfuscation in place when [o] is not null; since
  /// T1.3 the payload is also decrypted in place, so [data] is modified.
  static ({TlObject message, int messageId, int authKeyId, int? seqno})
      parseFrame(Uint8List data, Obfuscation? o, List<int> authKey) {
    final f = _Frame.parse(data, o, authKey);
    return (
      message: f.message,
      messageId: f.messageId,
      authKeyId: f.authKeyId,
      seqno: f.seqno,
    );
  }

  /// Receive pipeline for encrypted frames. With [sessionId], frames of
  /// another session are dropped (as in [Client]).
  static Stream<TlObject> encryptedReceiver(
    Stream<List<int>> raw,
    Obfuscation o,
    AuthorizationKey k,
    Set<int> acks, {
    int? sessionId,
  }) {
    return _EncryptedTransformer(raw, o, k, acks, sessionId: sessionId).stream;
  }

  /// Receive pipeline for unencrypted frames.
  static Stream<TlObject> unencryptedReceiver(
    Stream<List<int>> raw,
    Obfuscation? o,
    Set<int> acks,
  ) {
    return _UnEncryptedTransformer(raw, acks, o).stream;
  }

  /// Unencrypted frame with transport length prefix and obfuscation applied
  /// (what `_Frame.toUint8List` produces).
  static Uint8List frameToBytes(TlObject m, int msgId, Obfuscation? o) {
    return _Frame(m, msgId, 0, null).toUint8List(o);
  }
}
