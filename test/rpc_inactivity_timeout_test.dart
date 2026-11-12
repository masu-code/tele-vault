import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';
import 'package:tg/tg.dart' as tg;

/// F1: the per-RPC timeout of [TelegramService.call] is an inactivity timeout
/// on the socket (nothing received for [TelegramService.rpcInactivityTimeout])
/// plus an absolute cap ([TelegramService.rpcMaxDuration]), not a fixed total
/// time. A slow but steady link must not time out a long RPC (a 1 MiB getFile
/// window); true silence must. Timeouts are shortened here; the "server" is a
/// loopback socket that trickles bytes (or stays silent).
void main() {
  late ServerSocket server;
  final serverSides = <Socket>[];
  final ios = <IoSocket>[];
  final timers = <Timer>[];

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {
      serverSides.add(s);
      s.listen((_) {}, onError: (_) {});
    });
  });

  tearDown(() async {
    for (final t in timers) {
      t.cancel();
    }
    timers.clear();
    final svc = TelegramService.instance;
    svc.debugReconnectOverride = null;
    svc.idleProbeAfter = const Duration(seconds: 20);
    svc.probeTimeout = const Duration(seconds: 5);
    svc.probeReconnects = 0;
    svc.rpcInactivityTimeout = const Duration(seconds: 30);
    svc.rpcMaxDuration = const Duration(minutes: 5);
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
    io.receiver.listen((_) {}, onError: (_) {});
    ios.add(io);
    return io;
  }

  /// A client plus the socket [TelegramService] watches. The actions below
  /// never touch the client, so the bytes the "server" trickles on the watched
  /// socket only feed [IoSocket.lastReceive] (as a getFile in progress would).
  Future<(tg.Client, IoSocket)> newConnection() async {
    final clientSocket = await newSocket();
    final client = tg.Client(
      socket: clientSocket,
      obfuscation: tg.Obfuscation.random(false, 2),
      authorizationKey: tg.AuthorizationKey(1, Uint8List(256), 0),
      idGenerator: tg.MessageIdGenerator(),
    );
    final watched = await newSocket();
    return (client, watched);
  }

  /// Makes the server side of the most recent connection send one byte
  /// every [every].
  Future<void> trickle(Duration every) async {
    // Wait for the accept of the watched socket.
    final sw = Stopwatch()..start();
    while (serverSides.length < 2 && sw.elapsedMilliseconds < 2000) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final side = serverSides.last;
    timers.add(Timer.periodic(every, (_) {
      try {
        side.add(const [0]);
      } catch (_) {}
    }));
  }

  test('a slow but steady trickle longer than the timeout does not time out',
      () async {
    final svc = TelegramService.instance;
    svc.rpcInactivityTimeout = const Duration(milliseconds: 300);
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    io0.lastReceive = DateTime.now();
    var reconnects = 0;
    svc.debugReconnectOverride = () async => reconnects++;
    await trickle(const Duration(milliseconds: 40));

    final sw = Stopwatch()..start();
    var attempts = 0;
    final r = await svc.call<int>((c) {
      attempts++;
      // 4x the inactivity timeout in total, bytes arriving all along.
      return Future<int>.delayed(const Duration(milliseconds: 1200), () => 42);
    });
    sw.stop();

    expect(r, 42);
    expect(attempts, 1);
    expect(reconnects, 0);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1200));
    expect(svc.activeRpcWatchdogs, 0);
    expect(io0.onDeadCount, 0);
  });

  test('silence times out, reconnects once and retries', () async {
    final svc = TelegramService.instance;
    svc.rpcInactivityTimeout = const Duration(milliseconds: 250);
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    io0.lastReceive = DateTime.now();
    var reconnects = 0;
    svc.debugReconnectOverride = () async {
      reconnects++;
      final (c, io) = await newConnection();
      io.lastReceive = DateTime.now();
      svc.debugAttach(c, io);
    };

    var attempts = 0;
    final sw = Stopwatch()..start();
    final r = await svc.call<int>((c) {
      attempts++;
      // First attempt: an answer that never comes on a silent socket.
      if (attempts == 1) return Completer<int>().future;
      return Future.value(7);
    });
    sw.stop();

    expect(r, 7);
    expect(attempts, 2);
    expect(reconnects, 1);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(240));
    expect(sw.elapsedMilliseconds, lessThan(3000));
    expect(svc.activeRpcWatchdogs, 0);
  });

  test('silence on the retry too surfaces TimeoutException', () async {
    final svc = TelegramService.instance;
    svc.rpcInactivityTimeout = const Duration(milliseconds: 200);
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    io0.lastReceive = DateTime.now();
    svc.debugReconnectOverride = () async {
      final (c, io) = await newConnection();
      io.lastReceive = DateTime.now();
      svc.debugAttach(c, io);
    };

    await expectLater(
      svc.call<int>((c) => Completer<int>().future),
      throwsA(isA<TimeoutException>()),
    );
    expect(svc.activeRpcWatchdogs, 0);
  });

  test('the absolute cap still applies while bytes keep arriving', () async {
    final svc = TelegramService.instance;
    svc.rpcInactivityTimeout = const Duration(milliseconds: 300);
    svc.rpcMaxDuration = const Duration(milliseconds: 500);
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    io0.lastReceive = DateTime.now();
    var reconnects = 0;
    svc.debugReconnectOverride = () async {
      reconnects++;
      final (c, io) = await newConnection();
      io.lastReceive = DateTime.now();
      svc.debugAttach(c, io);
    };
    await trickle(const Duration(milliseconds: 40));

    var attempts = 0;
    final sw = Stopwatch()..start();
    final r = await svc.call<int>((c) {
      attempts++;
      if (attempts == 1) return Completer<int>().future;
      return Future.value(9);
    });
    sw.stop();

    expect(r, 9);
    expect(attempts, 2);
    expect(reconnects, 1);
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(490));
    expect(svc.activeRpcWatchdogs, 0);
  });

  test('no watchdog timer or on-dead callback is left after N calls',
      () async {
    final svc = TelegramService.instance;
    svc.rpcInactivityTimeout = const Duration(milliseconds: 200);
    final (c0, io0) = await newConnection();
    svc.debugAttach(c0, io0);
    io0.lastReceive = DateTime.now();
    svc.debugReconnectOverride = () async {
      final (c, io) = await newConnection();
      io.lastReceive = DateTime.now();
      svc.debugAttach(c, io);
    };

    for (var i = 0; i < 40; i++) {
      expect(await svc.call<int>((c) => Future.value(i)), i);
    }
    for (var i = 0; i < 5; i++) {
      await expectLater(
        svc.call<int>((c) => Future<int>.error(StateError('boom'))),
        throwsA(isA<StateError>()),
      );
    }
    // Several in flight at once, all settling.
    final many = await Future.wait(List.generate(
        10,
        (i) => svc.call<int>((c) =>
            Future<int>.delayed(Duration(milliseconds: 5 * i), () => i))));
    expect(many, List.generate(10, (i) => i));
    // One timeout (first attempt) followed by a successful retry.
    var attempts = 0;
    expect(
        await svc.call<int>((c) {
          attempts++;
          return attempts == 1 ? Completer<int>().future : Future.value(1);
        }),
        1);

    expect(svc.activeRpcWatchdogs, 0);
    expect(io0.onDeadCount, 0);
  });
}
