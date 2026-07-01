import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:tg/tg.dart' as tg;

/// Adapts a dart:io [Socket] to the tg [SocketAbstraction].
///
/// A raw socket is a single-subscription stream, but tg listens to [receiver]
/// more than once: first for the unencrypted auth handshake, then again for
/// the encrypted session. We subscribe to the socket exactly once and
/// re-broadcast, so multiple downstream listeners are allowed.
///
/// Robustness (Android/MIUI): the OS silently kills idle TCP connections. Two
/// failure modes were observed and are handled here:
///  - `flush()` on a dead socket hangs forever, stalling the whole send chain
///    (and every RPC behind it). We bound it with a timeout.
///  - Writing after the socket is closed throws raw "StreamSink is closed".
///    We mark the socket dead on the first failure (or on receive
///    done/error) and fail every later send fast with a [SocketDeadException],
///    so callers can detect it and reconnect instead of hanging or surfacing a
///    confusing dart:io StateError.
class IoSocket extends tg.SocketAbstraction {
  IoSocket(this._socket) {
    _socket.listen(
      _controller.add,
      onError: (Object e, StackTrace st) {
        // Mark dead but do NOT forward the error: tg.Client's stream listener
        // has no onError handler, so forwarding would cause an Unhandled
        // Exception. Pending RPCs will timeout via _withReconnect's .timeout().
        _markDead();
        if (!_controller.isClosed) _controller.close();
      },
      onDone: () {
        _markDead();
        if (!_controller.isClosed) _controller.close();
      },
      cancelOnError: false,
    );
  }

  final Socket _socket;
  final _controller = StreamController<Uint8List>.broadcast();

  /// Serializes writes: a dart:io socket can't be written to concurrently, and
  /// many requests run in parallel (gallery thumbnails + downloads). Each send
  /// waits for the previous one to finish flushing.
  Future<void> _sendChain = Future.value();

  /// Set once the socket is known to be unusable (closed by us or killed by the
  /// OS). After this, sends fail fast instead of hanging or throwing StateError.
  bool _dead = false;

  bool get isDead => _dead;

  void _markDead() => _dead = true;

  @override
  Stream<Uint8List> get receiver => _controller.stream;

  @override
  Future<void> send(List<int> data) {
    if (_dead) return Future.error(const SocketDeadException());
    final result = _sendChain.then((_) async {
      if (_dead) throw const SocketDeadException();
      try {
        _socket.add(data);
        // A dead socket's flush never completes; bound it so the chain (and
        // every queued RPC) can't stall forever.
        await _socket.flush().timeout(const Duration(seconds: 15));
      } catch (e) {
        _markDead();
        throw const SocketDeadException();
      }
    });
    // Keep the chain alive even if a send throws, so later sends still run.
    _sendChain = result.catchError((_) {});
    return result;
  }

  /// Simulates the OS (MIUI) silently killing the TCP connection mid-session.
  /// Marks the socket dead and destroys the underlying raw socket, reproducing
  /// exactly the condition the reconnect logic must recover from. Reached only
  /// through [TelegramService.debugKillSocket] (which is test-only).
  void debugKill() {
    _markDead();
    _socket.destroy();
  }

  Future<void> close() async {
    _markDead();
    try {
      await _socket.close().timeout(const Duration(seconds: 5));
    } catch (_) {
      _socket.destroy();
    }
    if (!_controller.isClosed) await _controller.close();
  }
}

/// Thrown by [IoSocket.send] when the socket is closed or has been killed by
/// the OS. Callers treat this as a transient transport failure and reconnect.
class SocketDeadException implements Exception {
  const SocketDeadException();
  @override
  String toString() => 'SocketDeadException: connection was closed';
}
