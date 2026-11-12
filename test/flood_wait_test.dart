import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:t/t.dart' as t;
import 'package:tele_vault/core/download/download_worker.dart';
import 'package:tele_vault/core/index/index_cache.dart';
import 'package:tele_vault/core/index/index_remote.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';
import 'package:tg/tg.dart' as tg;

/// FLOOD_WAIT is handled once, in [TelegramService.call]: a wait of up to
/// [TelegramService.maxFloodWaitSeconds] is waited out (N+1 s) and the same
/// action retried, at most [TelegramService.maxFloodWaitRetries] times; a
/// longer one fails fast with [FloodWaitException], which stays recognisable
/// across the worker isolate and surfaces as a typed [IndexException].

t.Result<t.Pong> _flood(int s) =>
    t.Result<t.Pong>.error(t.RpcError(errorCode: 420, errorMessage: 'FLOOD_WAIT_$s'));
const _ok = t.Result<t.Pong>.ok(t.Pong(msgId: 1, pingId: 2));

/// A top-level `call` function for the worker test: one RPC that is
/// flood-waited once (1 s), then answers.
Future<int> _floodedOnce(int _) async {
  var n = 0;
  final r = await TelegramService.instance.call((_) async => n++ == 0 ? _flood(1) : _ok);
  return r.error == null ? n : -1;
}

Future<int> _floodedLong(int _) async {
  await TelegramService.instance.call((_) async => _flood(500));
  return 0;
}

class _FloodRemote implements IndexRemote {
  @override
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args) async =>
      const RemoteIndexSnapshot(kind: RemoteIndexKind.none);

  @override
  Future<RemoteWriteResult> write(RemoteWriteArgs args) async =>
      throw const FloodWaitException(900);

  @override
  Future<List<int>?> existingMessageIds(List<int> messageIds) async => messageIds;

  @override
  Future<void> deleteMessages(List<int> messageIds) async {}

  @override
  Future<int?> documentIdOf(int messageId) async => null;

  @override
  Future<List<TransferableTypedData>> scanAllSnapshots(int maxMessages) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServerSocket server;
  final sockets = <IoSocket>[];
  final waits = <Duration>[];

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
    svc.debugFloodWaitDelay = (d) async => waits.add(d);
  });

  tearDown(() async {
    final svc = TelegramService.instance;
    svc.debugFloodWaitDelay = null;
    svc.idleProbeAfter = const Duration(seconds: 20);
    for (final s in sockets) {
      try {
        await s.close();
      } catch (_) {}
    }
    sockets.clear();
    await server.close();
  });

  test('FLOOD_WAIT_5 waits 6 s and retries the same action once', () async {
    var attempts = 0;
    final r = await TelegramService.instance.call((_) async {
      attempts++;
      return attempts == 1 ? _flood(5) : _ok;
    });
    expect(r.error, isNull);
    expect(attempts, 2);
    expect(waits, [const Duration(seconds: 6)]);
  });

  test('a FLOOD_WAIT still there after 3 retries throws FloodWaitException', () async {
    var attempts = 0;
    await expectLater(
      TelegramService.instance.call((_) async {
        attempts++;
        return _flood(7);
      }),
      throwsA(isA<FloodWaitException>().having((e) => e.seconds, 'seconds', 7)),
    );
    expect(attempts, 1 + TelegramService.maxFloodWaitRetries);
    expect(waits, List.filled(3, const Duration(seconds: 8)));
  });

  test('a FLOOD_WAIT over 120 s fails fast, without waiting', () async {
    var attempts = 0;
    await expectLater(
      TelegramService.instance.call((_) async {
        attempts++;
        return _flood(121);
      }),
      throwsA(isA<FloodWaitException>().having((e) => e.seconds, 'seconds', 121)),
    );
    expect(attempts, 1);
    expect(waits, isEmpty);
  });

  test('120 s is still waited out', () async {
    var attempts = 0;
    await TelegramService.instance.call((_) async => attempts++ == 0 ? _flood(120) : _ok);
    expect(waits, [const Duration(seconds: 121)]);
  });

  test('any other RPC error is returned unchanged, no retry', () async {
    var attempts = 0;
    final r = await TelegramService.instance.call((_) async {
      attempts++;
      return t.Result<t.Pong>.error(
          const t.RpcError(errorCode: 400, errorMessage: 'MESSAGE_ID_INVALID'));
    });
    expect(r.error!.errorMessage, 'MESSAGE_ID_INVALID');
    expect(attempts, 1);
    expect(waits, isEmpty);
  });

  test('on the worker, the wait reports progress and the retry succeeds', () async {
    // The real wait (1 + 1 s), so the worker-side progress touch is exercised.
    TelegramService.instance.debugFloodWaitDelay = null;
    final port = ReceivePort();
    final messages = <Map>[];
    final done = Completer<void>();
    port.listen((m) {
      messages.add(m as Map);
      if (m['type'] != 'progress') done.complete();
    });
    await handleRequestForTesting(
      {'type': 'call', 'id': 1, 'fn': _floodedOnce, 'arg': 0},
      port.sendPort,
      ensureSession: () async => true,
    );
    await done.future.timeout(const Duration(seconds: 10));
    port.close();
    expect(messages.last['result'], 2, reason: 'same action retried once, then ok');
    expect(messages.where((m) => m['type'] == 'progress'), isNotEmpty,
        reason: 'the wait touches the inactivity timeout of the caller');
  });

  test('a long FLOOD_WAIT crosses the worker boundary as FloodWaitException', () async {
    final port = ReceivePort();
    final reply = Completer<Map>();
    port.listen((m) {
      if ((m as Map)['type'] != 'progress') reply.complete(m);
    });
    await handleRequestForTesting(
      {'type': 'call', 'id': 2, 'fn': _floodedLong, 'arg': 0},
      port.sendPort,
      ensureSession: () async => true,
    );
    final m = await reply.future.timeout(const Duration(seconds: 10));
    port.close();
    final parsed = FloodWaitException.tryParse(m['error'] as String);
    expect(parsed?.seconds, 500);
  });

  test('IndexService.save surfaces it as an IndexException with the seconds', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('tv_flood_index_');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    final service = IndexService.forTesting(
      remote: _FloodRemote(),
      cache: IndexCache.inDirectory(Directory('${dir.path}${Platform.pathSeparator}idx')),
    );
    await service.load();
    await expectLater(
      service.save(await service.load()),
      throwsA(isA<IndexException>().having((e) => e.floodWaitSeconds, 'floodWaitSeconds', 900)),
    );
  });
}
