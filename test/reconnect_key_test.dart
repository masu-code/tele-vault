import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';
import 'package:tg/tg.dart' as tg;

/// I1: a failed reconnect must not lose the authorization key. Before the
/// fix, `_doReconnect` read the key from `_client`, which every reconnect path
/// nulls before its socket connect can fail; the next call then reconnected
/// with no key, i.e. a fresh, unregistered handshake.
void main() {
  late ServerSocket server;
  final serverSides = <Socket>[];
  final ios = <IoSocket>[];

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      serverSides.add(s);
      s.listen((_) {}, onError: (_) {});
    });
  });

  tearDown(() async {
    final svc = TelegramService.instance;
    svc.debugReconnectOverride = null;
    svc.debugConnectOverride = null;
    await svc.dropConnection();
    svc.debugForgetKey();
    for (final io in ios) {
      try {
        await io.close();
      } catch (_) {}
    }
    ios.clear();
    for (final s in serverSides) {
      s.destroy();
    }
    serverSides.clear();
    await server.close();
  });

  Future<(tg.Client, IoSocket)> connectionWith(tg.AuthorizationKey key) async {
    final raw =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final io = IoSocket(raw);
    io.receiver.listen((_) {}, onError: (_) {});
    io.lastReceive = DateTime.now();
    ios.add(io);
    final client = tg.Client(
      socket: io,
      obfuscation: tg.Obfuscation.random(false, 2),
      authorizationKey: key,
      idGenerator: tg.MessageIdGenerator(),
    );
    return (client, io);
  }

  test('a failed reconnect followed by a successful one reuses the same key',
      () async {
    final svc = TelegramService.instance;
    final sessionKey = tg.AuthorizationKey(77, Uint8List(256), 5);
    final (c0, io0) = await connectionWith(sessionKey);
    svc.debugAttach(c0, io0);

    final requested = <tg.AuthorizationKey?>[];
    svc.debugConnectOverride = (dcId, authKey) async {
      requested.add(authKey);
      if (requested.length == 1) {
        throw const SocketException('network down');
      }
      final (c, io) = await connectionWith(authKey!);
      svc.debugAttach(c, io, dcId: dcId);
    };

    // Reconnect #1 fails: _client is gone afterwards.
    await expectLater(svc.reconnect(), throwsA(isA<SocketException>()));
    expect(svc.isConnected, isFalse);

    // The next call reconnects (because _client == null) and must reuse the
    // session key, not handshake a new one.
    final used = await svc.call<tg.AuthorizationKey>(
        (c) => Future.value(c.authorizationKey));

    expect(requested, hasLength(2));
    expect(requested[0], same(sessionKey));
    expect(requested[1], same(sessionKey));
    expect(used.id, 77);
    expect(svc.isConnected, isTrue);
  });

  test('after a session, a reconnect with no key throws instead of handshaking',
      () async {
    final svc = TelegramService.instance;
    final (c0, io0) =
        await connectionWith(tg.AuthorizationKey(78, Uint8List(256), 0));
    svc.debugAttach(c0, io0);

    var connects = 0;
    svc.debugConnectOverride = (dcId, authKey) async => connects++;

    await svc.dropConnection();
    svc.debugForgetKey();

    await expectLater(
      svc.call<int>((c) => Future.value(1)),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('No authorization key'))),
    );
    await expectLater(
      svc.reconnect(),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('No authorization key'))),
    );
    expect(connects, 0);
    expect(svc.isConnected, isFalse);
  });

  test('dropConnection alone keeps the key for the next reconnect', () async {
    final svc = TelegramService.instance;
    final sessionKey = tg.AuthorizationKey(79, Uint8List(256), 0);
    final (c0, io0) = await connectionWith(sessionKey);
    svc.debugAttach(c0, io0);

    final requested = <tg.AuthorizationKey?>[];
    svc.debugConnectOverride = (dcId, authKey) async {
      requested.add(authKey);
      final (c, io) = await connectionWith(authKey!);
      svc.debugAttach(c, io, dcId: dcId);
    };

    await svc.dropConnection();
    expect(await svc.call<int>((c) => Future.value(3)), 3);
    expect(requested, [same(sessionKey)]);
  });
}
