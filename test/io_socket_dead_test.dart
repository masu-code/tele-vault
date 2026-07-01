import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';

/// Verifies the MIUI/dead-socket robustness of [IoSocket]: sends must fail fast
/// and cleanly (with [SocketDeadException]) instead of hanging forever or
/// leaking raw "StreamSink is closed" StateErrors.
void main() {
  test('sending after our own close() fails fast with SocketDeadException',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.listen((_) {}, onError: (_) {}));
    final client =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final io = IoSocket(client);
    final data = Uint8List.fromList(List.filled(1024, 2));

    await io.send(data);
    await io.close(); // reconnect() tears the socket down here

    for (var i = 0; i < 5; i++) {
      Object? err;
      try {
        await io.send(data);
      } catch (e) {
        err = e;
      }
      expect(err, isA<SocketDeadException>(),
          reason: 'must be a clean SocketDeadException, not a raw StateError');
    }
    expect(io.isDead, isTrue);

    await server.close();
  });

  test('peer killing the connection does not hang or throw unhandled exception',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Socket? serverSide;
    final serverErrors = <Object>[];
    server.listen((s) {
      serverSide = s;
      s.listen((_) {}, onError: serverErrors.add);
    });
    final client =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);

    // Simulate tg.Client: subscribe to receiver WITHOUT an onError handler.
    // If IoSocket forwards a SocketException here, the test harness catches it
    // as an unhandled async error and fails the test.
    final receiveErrors = <Object>[];
    final io = IoSocket(client);
    io.receiver.listen((_) {}, onError: receiveErrors.add);

    final data = Uint8List.fromList(List.filled(1024, 1));
    await io.send(data);

    serverSide?.destroy(); // MIUI-style kill
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Sends after peer-kill must fail fast, not hang.
    for (var i = 0; i < 20; i++) {
      Object? err;
      try {
        await io.send(data);
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull,
          reason: 'sends on a dead socket must reject, not hang');
    }
    expect(io.isDead, isTrue);
    // Critically: the receive stream must have emitted no errors (we close it
    // cleanly so tg.Client's unhandled-error listener is never triggered).
    expect(receiveErrors, isEmpty,
        reason: 'receive stream must not emit errors — tg.Client has no onError handler');

    await server.close();
  }, timeout: const Timeout(Duration(seconds: 25)));
}
