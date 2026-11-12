part of '../tg.dart';

class _PendingTask {
  final Completer<t.Result> completer;
  final t.TlMethod method;
  final List<int> sentAcks;

  /// TeleVault: when the request was (re)sent, for the 5 min sweep.
  final DateTime sentAt;

  /// TeleVault: already resent after a BadMsgNotification 16/17.
  final bool timeResent;

  _PendingTask(this.completer, this.method, this.sentAcks,
      {this.timeResent = false})
      : sentAt = DateTime.now();
}

/// Pending calls older than this are dropped (failed with a TimeoutException)
/// on the next invoke (TeleVault).
const _pendingMaxAge = Duration(minutes: 5);

/// Unacknowledged server messages are acked with a standalone MsgsAck after
/// this long without a request carrying them (TeleVault).
const _ackFlushAfter = Duration(seconds: 10);

class Client extends t.Client {
  Client({
    required this.socket,
    required this.obfuscation,
    required this.authorizationKey,
    required this.idGenerator,
  }) {
    _transformer = _EncryptedTransformer(
      socket.receiver,
      obfuscation,
      authorizationKey,
      msgsToAck,
      sessionId: _sessionId,
    );

    _transformer.frames.listen(
      _onFrame,
      onError: (Object error, StackTrace st) => failAllPending(error),
      onDone: _onReceiverDone,
    );
  }

  static Future<AuthorizationKey> authorize(
    SocketAbstraction socket,
    Obfuscation obfuscation,
    MessageIdGenerator idGenerator,
  ) async {
    final Set<int> msgsToAck = {};

    final uot = _UnEncryptedTransformer(
      socket.receiver,
      msgsToAck,
      obfuscation,
    );

    final dh = _DiffieHellman(
      socket,
      uot.stream,
      obfuscation,
      idGenerator,
    );
    final ak = await dh.exchange();

    await uot.dispose();
    return ak;
  }

  AuthorizationKey authorizationKey;
  final Obfuscation obfuscation;
  final SocketAbstraction socket;
  final MessageIdGenerator idGenerator;
  final Set<int> msgsToAck = {};

  late final _EncryptedTransformer _transformer;

  final Map<int, _PendingTask> _pendingTasks = {};

  final _streamController = StreamController<UpdatesBase>.broadcast();

  final int _sessionId = Random.secure().nextInt(0x7FFFFFFF);

  /// TeleVault: this connection's MTProto session id. Incoming frames of any
  /// other session are dropped.
  int get sessionId => _sessionId;

  /// TeleVault: the receive stream ended (socket closed).
  bool _receiverClosed = false;

  /// TeleVault: when acks were last sent, and the pending flush timer.
  DateTime _lastAckSentAt = DateTime.now();
  Timer? _ackTimer;

  Stream<UpdatesBase> get stream => _streamController.stream;

  void _onFrame(_Frame frame) {
    _handleIncomingMessage(frame.message, frame.messageId);
    _scheduleAckFlush();
  }

  void _onReceiverDone() {
    _receiverClosed = true;
    _ackTimer?.cancel();
    _ackTimer = null;
    failAllPending(StateError('tg: connection closed'));
  }

  /// Fails every pending call with [error] (TeleVault). Called automatically
  /// when the receive stream closes or reports an error.
  void failAllPending(Object error) {
    if (_pendingTasks.isEmpty) return;
    final tasks = _pendingTasks.values.toList();
    _pendingTasks.clear();
    for (final task in tasks) {
      if (!task.completer.isCompleted) task.completer.completeError(error);
    }
  }

  /// Sends `ping` and waits for the matching `pong` (TeleVault).
  Future<void> ping() async {
    final r = await invoke(Ping(pingId: _rng.nextInt(0x7FFFFFFF)));
    final error = r.error;
    if (error != null) {
      throw RpcException._(error.errorCode, error.errorMessage);
    }
  }

  /// Drops pending calls older than [_pendingMaxAge] (TeleVault). Insertion
  /// order is send order, so the scan stops at the first young entry.
  void _dropStalePending() {
    if (_pendingTasks.isEmpty) return;
    final cutoff = DateTime.now().subtract(_pendingMaxAge);
    final stale = <int>[];
    for (final e in _pendingTasks.entries) {
      if (e.value.sentAt.isAfter(cutoff)) break;
      stale.add(e.key);
    }
    for (final id in stale) {
      final task = _pendingTasks.remove(id);
      if (task != null && !task.completer.isCompleted) {
        task.completer.future.ignore();
        task.completer.completeError(
            TimeoutException('tg: no answer', _pendingMaxAge));
      }
    }
  }

  void _scheduleAckFlush() {
    if (msgsToAck.isEmpty || _ackTimer != null || _receiverClosed) return;
    _ackTimer = Timer(_ackFlushAfter, _flushAcks);
  }

  /// Sends a standalone MsgsAck when acks have waited [_ackFlushAfter]
  /// without a request to carry them (TeleVault).
  void _flushAcks() {
    _ackTimer = null;
    if (msgsToAck.isEmpty || _receiverClosed) return;
    final waited = DateTime.now().difference(_lastAckSentAt);
    if (waited < _ackFlushAfter) {
      _ackTimer = Timer(_ackFlushAfter - waited, _flushAcks);
      return;
    }
    final ackMsg = MsgsAck(msgIds: msgsToAck.toList());
    msgsToAck.clear();
    _lastAckSentAt = DateTime.now();
    final buffer = _encodeWithAuth(
      ackMsg,
      idGenerator._next(false),
      _sessionId,
      authorizationKey,
    );
    obfuscation.send.encryptDecrypt(buffer, buffer.length);
    socket.send(buffer).then((_) {}, onError: (Object _) {});
  }

  /// Sets the generator's tick offset (100 ns units) from a server msg_id
  /// (about unixtime * 2^32) (TeleVault).
  void _syncServerTime(int serverMsgId) {
    final seconds = serverMsgId >> 32;
    final fraction = serverMsgId & 0xFFFFFFFF;
    final serverTicks = seconds * 10000000 + ((fraction * 10000000) >> 32);
    final localTicks = DateTime.now().toUtc().microsecondsSinceEpoch * 10;
    idGenerator.serverTicksOffset = serverTicks - localTicks;
  }

  /// Resends [task]; a failure to send fails its caller (TeleVault: the
  /// original left the error of the internal future unhandled).
  void _resend(_PendingTask task, {bool timeResent = false}) {
    _invoke(task.method, task.completer, timeResent: timeResent).then(
      (_) {},
      onError: (Object e, StackTrace st) {
        if (!task.completer.isCompleted) task.completer.completeError(e, st);
      },
    );
  }

  void _handleIncomingMessage(TlObject msg, [int? serverMsgId]) {
    if (msg is UpdatesBase) {
      _streamController.add(msg);
    }

    if (msg is MsgContainer) {
      for (final message in msg.messages) {
        _handleIncomingMessage(message, serverMsgId);
      }
      return;
    } else if (msg is Msg) {
      if ((msg.seqno & 1) != 0) {
        msgsToAck.add(msg.msgId);
      }
      _handleIncomingMessage(msg.body, msg.msgId);
      return;
    } else if (msg is BadMsgNotification) {
      final badMsgId = msg.badMsgId;
      final task = _pendingTasks.remove(badMsgId);
      final timeError = msg.errorCode == 16 || msg.errorCode == 17;
      if (timeError && serverMsgId != null) {
        // TeleVault: msg_id too low/high -> sync with the server clock.
        _syncServerTime(serverMsgId);
        if (msg.errorCode == 17) {
          // Ids generated with the fast clock were rejected; let the next id
          // follow the corrected clock instead of `last + 4`.
          idGenerator._lastSentMessageId = 0;
        }
      }
      if (task != null) {
        if (timeError && serverMsgId != null && !task.timeResent) {
          _resend(task, timeResent: true);
        } else if (!task.completer.isCompleted) {
          task.completer.completeError(BadMessageException._(msg));
        }
      }
    } else if (msg is Pong) {
      // TeleVault: the original never completed a ping.
      final task = _pendingTasks.remove(msg.msgId);
      if (task != null && !task.completer.isCompleted) {
        task.completer.complete(t.Result.ok(msg));
      }
    } else if (msg is RpcResult) {
      final reqMsgId = msg.reqMsgId;
      final task = _pendingTasks[reqMsgId];

      final result = msg.result;

      if (result is RpcError) {
        task?.completer.complete(t.Result.error(result));
        _pendingTasks.remove(reqMsgId);
        return;
      } else if (result is GzipPacked) {
        final gZippedData = GZipDecoder().decodeBytes(result.packedData);

        final newObj = FastBinaryReader(gZippedData).readObject();

        final newRpcResult = RpcResult(reqMsgId: reqMsgId, result: newObj);
        _handleIncomingMessage(newRpcResult, serverMsgId);
        return;
      }
      task?.completer.complete(t.Result.ok(msg.result));
      _pendingTasks.remove(reqMsgId);
    } else if (msg is GzipPacked) {
      final gZippedData = GZipDecoder().decodeBytes(msg.packedData);
      final newObj = FastBinaryReader(gZippedData).readObject();
      _handleIncomingMessage(newObj, serverMsgId);
    } else if (msg is NewSessionCreated) {
      authorizationKey = AuthorizationKey(
        authorizationKey.id,
        authorizationKey.key,
        msg.serverSalt,
      );
    } else if (msg is BadServerSalt) {
      authorizationKey = AuthorizationKey(
        authorizationKey.id,
        authorizationKey.key,
        msg.newServerSalt,
      );

      final badMsgId = msg.badMsgId;
      final task = _pendingTasks.remove(badMsgId);

      if (task != null) {
        if (task.sentAcks.isNotEmpty) {
          msgsToAck.addAll(task.sentAcks);
        }
        _resend(task, timeResent: task.timeResent);
      }
    }
  }

  @override
  Future<t.Result<t.TlObject>> invoke(t.TlMethod method) {
    return _invoke(method, Completer<t.Result>());
  }

  Future<t.Result<t.TlObject>> _invoke(
    t.TlMethod method,
    Completer<t.Result> completer, {
    bool timeResent = false,
  }) async {
    if (_receiverClosed) {
      throw StateError('tg: connection closed');
    }
    _dropStalePending();

    final preferEncryption = authorizationKey.id != 0;

    final m = idGenerator._next(preferEncryption);
    List<int> currentAcks = [];

    if (preferEncryption && msgsToAck.isNotEmpty) {
      currentAcks = msgsToAck.toList();
      final ack = idGenerator._next(false);
      final ackMsg = MsgsAck(msgIds: currentAcks);
      msgsToAck.clear();

      // final container = MsgContainer(
      //   messages: [
      //     Msg(msgId: m.id, seqno: m.seqno, bytes: 0, body: method),
      //     Msg(msgId: ack.id, seqno: ack.seqno, bytes: 0, body: ackMsg),
      //   ],
      // );

      // void nop(TlObject o) {
      //   //
      // }

      // nop(container);

      //return invoke(container, false);

      final ackBuffer = _encodeWithAuth(
        ackMsg,
        ack,
        _sessionId,
        authorizationKey,
      );
      obfuscation.send.encryptDecrypt(ackBuffer, ackBuffer.length);
      _lastAckSentAt = DateTime.now();
      await socket.send(ackBuffer);
    }

    _pendingTasks[m.id] = _PendingTask(completer, method, currentAcks,
        timeResent: timeResent);
    final buffer = authorizationKey.id == 0
        ? _encodeNoAuth(method, m)
        : _encodeWithAuth(method, m, _sessionId, authorizationKey);

    obfuscation.send.encryptDecrypt(buffer, buffer.length);
    try {
      await socket.send(buffer);
    } catch (_) {
      // TeleVault: the original left the entry in _pendingTasks forever.
      _pendingTasks.remove(m.id);
      rethrow;
    }

    return completer.future;
  }
}
