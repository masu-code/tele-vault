import 'dart:io';
import 'dart:typed_data';
import 'package:tg/tg.dart' as tg;

class IoSocket extends tg.SocketAbstraction {
  IoSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get receiver => _socket;

  @override
  Future<void> send(List<int> data) async {
    _socket.add(data);
    await _socket.flush();
  }

  Future<void> close() => _socket.close();
}
