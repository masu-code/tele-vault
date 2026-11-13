import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:t/t.dart' as t;
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';
import 'package:tele_vault/core/thumbnail/server_thumb_batch.dart';
import 'package:tg/tg.dart' as tg;

import 'support/fake_flood_time.dart';

/// The shared flood gate of [TelegramService.call]: one FLOOD_WAIT pauses every
/// caller of the isolate once (instead of each hitting its own), overlapping
/// waits keep the later opening, and each gate logs a single line. Run on a
/// fake clock, nothing really sleeps.

t.Result<t.Pong> _flood(int s) =>
    t.Result<t.Pong>.error(t.RpcError(errorCode: 420, errorMessage: 'FLOOD_WAIT_$s'));
const _ok = t.Result<t.Pong>.ok(t.Pong(msgId: 1, pingId: 2));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServerSocket server;
  final sockets = <IoSocket>[];
  final waits = <Duration>[];
  late FakeFloodTime fake;
  late DateTime t0;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.listen((_) {}, onError: (_) {}));
    Future<IoSocket> socket() async {
      final io = IoSocket(await Socket.connect(InternetAddress.loopbackIPv4, server.port));
      io.receiver.listen((_) {}, onError: (_) {});
      io.lastReceive = DateTime.now();
      sockets.add(io);
      return io;
    }

    final client = tg.Client(
      socket: await socket(),
      obfuscation: tg.Obfuscation.random(false, 2),
      authorizationKey: tg.AuthorizationKey(1, Uint8List(256), 0),
      idGenerator: tg.MessageIdGenerator(),
    );
    final svc = TelegramService.instance;
    svc.debugAttach(client, await socket());
    svc.idleProbeAfter = const Duration(hours: 1);
    waits.clear();
    fake = FakeFloodTime(waits)..install(svc);
    t0 = fake.now;
  });

  tearDown(() async {
    final svc = TelegramService.instance;
    FakeFloodTime.uninstall(svc);
    svc.idleProbeAfter = const Duration(seconds: 20);
    for (final s in sockets) {
      try {
        await s.close();
      } catch (_) {}
    }
    sockets.clear();
    await server.close();
  });

  /// Runs [body] collecting every line it prints.
  Future<List<String>> logOf(Future<void> Function() body) async {
    final lines = <String>[];
    await runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      ),
    );
    return lines;
  }

  Future<void> untilGateCloses() async {
    while (TelegramService.instance.floodGateUntil == null) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('one flood wait pauses every concurrent caller once', () async {
    final svc = TelegramService.instance;
    final startedAt = <String, DateTime>{};
    final logs = await logOf(() async {
      fake.hold = Completer<void>();
      var aCalls = 0;
      final a = svc.call((_) async {
        startedAt['a$aCalls'] = fake.now;
        return aCalls++ == 0 ? _flood(5) : _ok;
      });
      await untilGateCloses();
      // B, C and D start while the gate is closed: none may reach Telegram yet.
      final others = [
        for (final name in ['b', 'c', 'd'])
          svc.call((_) async {
            startedAt[name] = fake.now;
            return _ok;
          }),
      ];
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(startedAt.keys, ['a0'], reason: 'the gate holds B, C, D back');
      fake.hold!.complete();
      await Future.wait([a, ...others]);
    });

    const gate = Duration(seconds: 6);
    expect(startedAt['a0'], t0);
    for (final name in ['a1', 'b', 'c', 'd']) {
      expect(startedAt[name], t0.add(gate), reason: '$name waited for the gate');
    }
    expect(startedAt.length, 5, reason: 'A twice, B, C, D once: no extra flood');
    expect(waits, hasLength(4));
    expect(waits, everyElement(gate));
    expect(logs.where((l) => l.contains('flood gate')), hasLength(1));
  });

  test('the gate is the latest of overlapping waits and never shortens', () async {
    final svc = TelegramService.instance;
    var calls = 0;
    final retryAt = <DateTime>[];
    final logs = await logOf(() async {
      Future<t.Result<t.Pong>> flooded(int seconds) {
        var n = 0;
        return svc.call((_) async {
          if (n++ == 0) return _flood(seconds);
          retryAt.add(fake.now);
          calls++;
          return _ok;
        });
      }

      // All three are in flight when the first flood closes the gate.
      fake.hold = Completer<void>();
      final all = Future.wait([flooded(5), flooded(20), flooded(3)]);
      await untilGateCloses();
      // Let every flood answer land before looking at the gate.
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(svc.floodGateUntil, t0.add(const Duration(seconds: 21)));
      fake.hold!.complete();
      await all;
    });

    expect(calls, 3);
    expect(retryAt, everyElement(t0.add(const Duration(seconds: 21))),
        reason: 'every retry waited for the 20 s gate, not the 5 s one');
    expect(logs.where((l) => l.contains('flood gate')), hasLength(1),
        reason: 'floods inside an open gate only extend it');
  });

  test('a gate that has already passed does not delay anyone', () async {
    final svc = TelegramService.instance;
    var n = 0;
    await svc.call((_) async => n++ == 0 ? _flood(2) : _ok);
    waits.clear();
    final r = await svc.call((_) async => _ok);
    expect(r.error, isNull);
    expect(waits, isEmpty);
  });

  test('the flood log fires once per gate, with the concurrency', () async {
    final svc = TelegramService.instance;
    final limiter = serverThumbLimiter; // wires TelegramService.onFloodGate
    final before = limiter.limit;
    final logs = await logOf(() async {
      var n = 0;
      await svc.call((_) async => n++ == 0 ? _flood(4) : _ok);
      n = 0;
      await svc.call((_) async => n++ == 0 ? _flood(1) : _ok);
    });
    final lines = logs.where((l) => l.startsWith('TVDIAG: flood gate')).toList();
    expect(lines, hasLength(2), reason: 'two gates, one line each');
    expect(lines.first, 'TVDIAG: flood gate 4s (concurrency=${before ~/ 2 < 1 ? 1 : before ~/ 2})');
    expect(logs.where((l) => l.contains('FLOOD_WAIT')), isEmpty,
        reason: 'no per-call retry lines');
    expect(limiter.limit, lessThan(before), reason: 'the flood halved the bulk fetch');
  });

  test('FLOOD_WAIT over 120 s fails its caller but does not close the gate', () async {
    final svc = TelegramService.instance;
    await expectLater(
      svc.call((_) async => _flood(500)),
      throwsA(isA<FloodWaitException>()),
    );
    expect(svc.floodGateUntil, isNull);
  });
}
