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
class IoSocket extends tg.SocketAbstraction {
  IoSocket(this._socket) {
    _socket.listen(
      _controller.add,
      onError: _controller.addError,
      onDone: _controller.close,
      cancelOnError: false,
    );
  }

  final Socket _socket;
  final _controller = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get receiver => _controller.stream;

  @override
  Future<void> send(List<int> data) async {
    _socket.add(data);
    await _socket.flush();
  }

  Future<void> close() async {
    await _socket.close();
    if (!_controller.isClosed) await _controller.close();
  }
}
