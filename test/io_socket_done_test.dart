import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';
import 'package:tg/tg.dart' as tg;

/// Transport liveness: [IoSocket.done] / [IoSocket.lastReceive] and the
/// fail-fast + idle-probe paths of [TelegramService.call]. Everything runs
/// against loopback sockets; the "server" never answers an RPC, which is what
/// a silently dropped connection looks like from the client side.
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
    svc.idleProbeAfter = const Duration(seconds: 20);
    svc.probeTimeout = const Duration(seconds: 5);
    svc.probeReconnects = 0;
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

  Future<IoSocket> newSocket() async {
    final raw =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final io = IoSocket(raw);
    ios.add(io);
    return io;
  }

  Future<(tg.Client, IoSocket)> newConnection() async {
    final io = await newSocket();
    final client = tg.Client(
      socket: io,
      obfuscation: tg.Obfuscation.random(false, 2),
      authorizationKey: tg.AuthorizationKey(1, Uint8List(256), 0),
      idGenerator: tg.MessageIdGenerator(),
    );
    return (client, io);
  }

  test('done completes when we close the socket', () async {
    final io = await newSocket();
    var completed = false;
    io.done.then((_) => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(completed, isFalse);

    await io.close();
    await io.done.timeout(const Duration(seconds: 1));
    expect(io.isDead, isTrue);
  });

  test('done completes when the peer kills the connection', () async {
    final io = await newSocket();
    io.receiver.listen((_) {}, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    serverSides.single.destroy();
    await io.done.timeout(const Duration(seconds: 2));
    expect(io.isDead, isTrue);
  });

  test('lastReceive advances when bytes arrive', () async {
    final io = await newSocket();
    io.receiver.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final before = io.lastReceive;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    serverSides.single.add([1, 2, 3]);
    await serverSides.single.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(io.lastReceive.isAfter(before), isTrue);
  });

  test('a socket dying mid-request fails the in-flight call in < 100 ms',
      () async {
    final svc = TelegramService.instance;
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    svc.debugReconnectOverride = () async {
      final (c, io) = await newConnection();
      svc.debugAttach(c, io);
    };

    var attempts = 0;
    final sw = Stopwatch()..start();
    Timer(const Duration(milliseconds: 20), svc.debugKillSocket);
    final result = await svc.call<int>((c) {
      attempts++;
      // First attempt: an RPC nobody answers. Retry: returns at once.
      if (attempts == 1) return c.help.getNearestDc().then((_) => -1);
      return Future.value(42);
    });
    sw.stop();

    expect(result, 42);
    expect(attempts, 2);
    expect(sw.elapsedMilliseconds, lessThan(100),
        reason: 'must not wait for the 30 s RPC timeout');
  });

  test('call on an already dead socket throws SocketDeadException fast',
      () async {
    final svc = TelegramService.instance;
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    // The first call's pre-check reconnects; make that reconnect hand back
    // another dead socket so the retry path also sees it.
    final (c1, io1) = await newConnection();
    svc.debugReconnectOverride = () async => svc.debugAttach(c1, io1);
    await io1.close();
    await io0.close();

    final sw = Stopwatch()..start();
    await expectLater(
      svc.call<int>((c) => c.help.getNearestDc().then((_) => 1)),
      throwsA(isA<SocketDeadException>()),
    );
    expect(sw.elapsedMilliseconds, lessThan(100));
  });

  test('idle probe failure triggers exactly one reconnect for N callers',
      () async {
    final svc = TelegramService.instance;
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    svc.idleProbeAfter = const Duration(seconds: 20);
    svc.probeTimeout = const Duration(milliseconds: 200);
    io0.lastReceive = DateTime.now().subtract(const Duration(minutes: 1));

    var reconnects = 0;
    svc.debugReconnectOverride = () async {
      reconnects++;
      final (c, io) = await newConnection();
      svc.debugAttach(c, io);
    };

    final seenClients = <tg.Client>[];
    final results = await Future.wait(List.generate(5, (_) {
      return svc.call<int>((c) {
        seenClients.add(c);
        return Future.value(7);
      });
    }));

    expect(results, everyElement(7));
    expect(reconnects, 1, reason: 'one probe, one shared reconnect');
    expect(svc.probeReconnects, 1);
    // The real action ran on the fresh connection, never on the stale one.
    expect(seenClients.any((c) => identical(c, c0)), isFalse);
  });

  test('a recent receive skips the probe entirely', () async {
    final svc = TelegramService.instance;
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    io0.lastReceive = DateTime.now();
    var reconnects = 0;
    svc.debugReconnectOverride = () async => reconnects++;

    final r = await svc.call<int>((c) => Future.value(5));
    expect(r, 5);
    expect(reconnects, 0);
    expect(svc.probeReconnects, 0);
  });

  test('on-dead callbacks are removed once each RPC settles (no leak)',
      () async {
    final svc = TelegramService.instance;
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    io0.lastReceive = DateTime.now();

    for (var i = 0; i < 50; i++) {
      expect(await svc.call<int>((c) => Future.value(i)), i);
    }
    for (var i = 0; i < 5; i++) {
      await expectLater(
        svc.call<int>((c) => Future<int>.error(StateError('boom'))),
        throwsA(isA<StateError>()),
      );
    }
    expect(io0.onDeadCount, 0);
  });

  test('on-dead callback fires once and in-flight call fails with it',
      () async {
    final io = await newSocket();
    var fired = 0;
    io.addOnDead(() => fired++);
    final removed = () => fired += 100;
    io.addOnDead(removed);
    io.removeOnDead(removed);
    expect(io.onDeadCount, 1);

    await io.close();
    await io.close();
    expect(fired, 1);
    expect(io.onDeadCount, 0);

    // Registering on an already-dead socket fires immediately.
    io.addOnDead(() => fired++);
    expect(fired, 2);
  });
}
