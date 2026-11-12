part of '../tg.dart';

// TeleVault: both transformers reassemble frames with RecvBuffer (the original
// used a List<int> with take/skip/removeRange). CTR order is unchanged: the 4
// length bytes are decrypted once (on a copy), then the body inside
// `_Frame.parse`. Errors of the raw stream are forwarded and its end closes
// the output stream, so a client can fail its pending calls.

class _EncryptedTransformer {
  _EncryptedTransformer(
    this._receiver,
    this._obfuscation,
    this._authorizationKey,
    this._msgsToAck, {
    int? sessionId,
  }) : _sessionId = sessionId {
    _receiver.listen(
      _readFrame,
      onError: _frames.addError,
      onDone: _frames.close,
    );
  }

  //StreamSubscription<List<int>>? _subscription;

  final _frames = StreamController<_Frame>.broadcast();

  /// Decoded frames (message plus its server msg_id and seqno).
  Stream<_Frame> get frames => _frames.stream;

  Stream<TlObject> get stream => _frames.stream.map((f) => f.message);

  final Stream<List<int>> _receiver;
  final Obfuscation _obfuscation;
  final AuthorizationKey _authorizationKey;
  final Set<int> _msgsToAck;

  /// TeleVault: the client's session id; frames of another session are
  /// dropped. Null skips the check (test/bench receivers).
  final int? _sessionId;

  final RecvBuffer _read = RecvBuffer();

  void _decryptLength(Uint8List four) {
    _obfuscation.recv.encryptDecrypt(four, 4);
  }

  void _readFrame(List<int> l) {
    _read.add(l);

    while (true) {
      final length = _read.peekLengthDecrypted(_decryptLength);
      if (length == null) break;

      final buffer = _read.takeFrame(length);
      if (buffer == null) break;

      // TeleVault (T1.4): a frame that fails verification (or does not parse)
      // is dropped and logged; nothing may throw out of the stream listener.
      // CTR already advanced past the body, so the next frame stays in sync.
      // Only frames under our own auth key are accepted: a plaintext frame
      // (auth_key_id 0) has no msg_key and could be injected by anyone who
      // saw the obfuscation preamble.
      final _Frame frame;
      try {
        frame = _Frame.parse(
          buffer,
          _obfuscation,
          _authorizationKey._keyBytes,
          expectedAuthKeyId: _authorizationKey.id,
          expectedSessionId: _sessionId,
        );
      } catch (e) {
        final reason = e is _FrameDropped
            ? e.reason
            : 'parse error (${e.runtimeType})';
        print('TVDIAG: tg dropped frame: $reason');
        continue;
      }

      final seqno = frame.seqno;

      if (seqno != null && (seqno & 1) != 0) {
        _msgsToAck.add(frame.messageId);
      }

      _frames.add(frame);
    }
  }
}

class _UnEncryptedTransformer {
  _UnEncryptedTransformer(
    this._receiver,
    this._msgsToAck,
    this._obfuscation,
  ) {
    _subscription = _receiver.listen(
      _readFrame,
      onError: _streamController.addError,
      onDone: _streamController.close,
    );
  }

  StreamSubscription<List<int>>? _subscription;

  Future<void> dispose() async {
    await _subscription?.cancel();
  }

  final _streamController = StreamController<TlObject>.broadcast();
  Stream<TlObject> get stream => _streamController.stream;

  final Stream<List<int>> _receiver;
  final Obfuscation? _obfuscation;
  final Set<int> _msgsToAck;
  final RecvBuffer _read = RecvBuffer(4096);

  void _decryptLength(Uint8List four) {
    _obfuscation?.recv.encryptDecrypt(four, 4);
  }

  void _readFrame(List<int> l) {
    _read.add(l);
    while (true) {
      final length = _read.peekLengthDecrypted(_decryptLength);
      if (length == null) break;

      final buffer = _read.takeFrame(length);
      if (buffer == null) break;

      final frame = _Frame.parse(buffer, _obfuscation, const []);
      final seqno = frame.seqno;

      if (seqno != null && (seqno & 1) != 0) {
        _msgsToAck.add(frame.messageId);
      }

      _streamController.add(frame.message);
    }
  }
}
