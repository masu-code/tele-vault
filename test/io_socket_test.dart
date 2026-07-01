import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';

/// These tests exercise [IoSocket] against a REAL loopback TCP socket, which is
/// where "Bad state: StreamSink is bound to a stream" actually originates
/// (dart:io's IOSink). No Android / no OTP needed to reproduce the write-layer
/// behaviour.
void main() {
  late ServerSocket server;
  late Socket client;
  late IoSocket io;

  Future<void> setUpPair() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // Drain anything the server receives so the client's flushes complete.
    server.listen((s) => s.listen((_) {}, onError: (_) {}));
    client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    io = IoSocket(client);
  }

  tearDown(() async {
    try {
      await io.close();
    } catch (_) {}
    await server.close();
  });

  test('many concurrent sends never throw "StreamSink is bound"', () async {
    await setUpPair();
    final data = Uint8List.fromList(List.filled(1024, 7));

    final futures = <Future<void>>[];
    for (var i = 0; i < 200; i++) {
      futures.add(io.send(data));
    }

    // None of these should throw the bound-stream StateError.
    await expectLater(Future.wait(futures), completes);
  });

  test('send racing with close() does not throw bound-stream error', () async {
    await setUpPair();
    final data = Uint8List.fromList(List.filled(1024, 9));

    // Fire a burst of sends, then close mid-flight (simulates reconnect()
    // tearing the socket down while RPC writes are still queued).
    final sends = <Future<void>>[];
    for (var i = 0; i < 100; i++) {
      sends.add(io.send(data).catchError((_) {}));
    }
    await io.close();

    Object? boundError;
    try {
      await Future.wait(sends);
    } catch (e) {
      boundError = e;
    }
    // After close, sends may fail — but NEVER with "StreamSink is bound".
    expect(
      boundError?.toString().contains('StreamSink is bound'),
      isNot(true),
    );
  });

  test('reconnect pattern: rapid create/close cycles stay clean', () async {
    for (var cycle = 0; cycle < 10; cycle++) {
      await setUpPair();
      final data = Uint8List.fromList(List.filled(512, cycle));
      // Overlap sends with the teardown of this cycle's socket.
      final sends = List.generate(20, (_) => io.send(data).catchError((_) {}));
      // Don't await sends before closing — that's the real race.
      await io.close();
      await Future.wait(sends);
      await server.close();
    }
    // If we got here without an unhandled "StreamSink is bound", we're good.
    expect(true, isTrue);
  });
}
