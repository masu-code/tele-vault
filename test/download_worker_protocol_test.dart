import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/download/download_service.dart';
import 'package:tele_vault/core/download/download_worker.dart';

Future<int> _double(int x) async => x * 2;

Future<String> _reportsProgress(int n) async {
  for (var i = 1; i <= n; i++) {
    WorkerProgress.report(i);
  }
  return 'done';
}

Future<void> _boom(int _) async => throw DownloadException('kaboom');

/// Fake worker side: a ReceivePort whose messages (the requests the main side
/// sends) are collected; the test answers by calling `deliverForTesting`.
class _FakeWorker {
  _FakeWorker() {
    port.listen((m) {
      requests.add((m as Map).cast<String, dynamic>());
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    });
    worker = DownloadWorker.forTesting(port.sendPort);
  }

  final ReceivePort port = ReceivePort();
  late final DownloadWorker worker;
  final List<Map<String, dynamic>> requests = [];
  final List<Completer<void>> _waiters = [];

  Future<Map<String, dynamic>> nextRequest() async {
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
    return requests.last;
  }

  void close() => port.close();
}

void main() {
  tearDown(() {
    DownloadWorker.enabled = false;
    DownloadWorker.defaultInactivityTimeout = const Duration(seconds: 60);
  });

  group('DownloadWorker request protocol', () {
    test('run sends a call message and returns the result', () async {
      DownloadWorker.enabled = true;
      final fake = _FakeWorker();
      addTearDown(fake.close);
      // Static run() goes through DownloadWorker.instance: exercise the
      // instance protocol through the same message shape instead.
      final req = fake.nextRequest();
      final future = fake.worker
          .runForTesting<int, int>(_double, 21, inactivityTimeout: const Duration(seconds: 5));
      final msg = await req;
      expect(msg['type'], 'call');
      expect(msg['fn'], same(_double));
      expect(msg['arg'], 21);
      fake.worker.deliverForTesting({'id': msg['id'], 'result': 42});
      expect(await future, 42);
      expect(fake.worker.pendingCount, 0);
    });

    test('error reply becomes DownloadException', () async {
      final fake = _FakeWorker();
      addTearDown(fake.close);
      final req = fake.nextRequest();
      final future = fake.worker
          .runForTesting<int, void>(_boom, 0, inactivityTimeout: const Duration(seconds: 5));
      final msg = await req;
      fake.worker.deliverForTesting({'id': msg['id'], 'error': 'kaboom'});
      await expectLater(
        future,
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', 'kaboom')),
      );
      expect(fake.worker.pendingCount, 0);
    });

    test('progress reaches onProgress and a late reply after timeout is ignored', () async {
      final fake = _FakeWorker();
      addTearDown(fake.close);
      final seen = <Object>[];
      final req = fake.nextRequest();
      final future = fake.worker.runForTesting<int, int>(
        _double,
        1,
        inactivityTimeout: const Duration(milliseconds: 80),
        onProgress: seen.add,
      );
      final msg = await req;
      fake.worker.deliverForTesting({'id': msg['id'], 'type': 'progress', 'value': 0.5});
      expect(seen, [0.5]);

      await expectLater(
        future,
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', 'timeout')),
      );
      expect(fake.worker.pendingCount, 0);

      // Late progress and late final reply for the timed-out id: no throw, no
      // callback, nothing resurrected.
      fake.worker.deliverForTesting({'id': msg['id'], 'type': 'progress', 'value': 0.9});
      fake.worker.deliverForTesting({'id': msg['id'], 'result': 2});
      expect(seen, [0.5]);
      expect(fake.worker.pendingCount, 0);
    });

    test('timeout fires with no reply at all', () async {
      final fake = _FakeWorker();
      addTearDown(fake.close);
      final sw = Stopwatch()..start();
      final future = fake.worker.runForTesting<int, int>(
        _double,
        1,
        inactivityTimeout: const Duration(milliseconds: 60),
      );
      await expectLater(future, throwsA(isA<DownloadException>()));
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(fake.worker.pendingCount, 0);
    });

    test('progress messages keep the request alive', () async {
      final fake = _FakeWorker();
      addTearDown(fake.close);
      final req = fake.nextRequest();
      final future = fake.worker.runForTesting<int, int>(
        _double,
        1,
        inactivityTimeout: const Duration(milliseconds: 120),
        onProgress: (_) {},
      );
      final msg = await req;
      // 6 x 50 ms = 300 ms total, longer than the 120 ms inactivity window.
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        fake.worker.deliverForTesting({'id': msg['id'], 'type': 'progress', 'value': i / 6});
      }
      fake.worker.deliverForTesting({'id': msg['id'], 'result': 7});
      expect(await future, 7);
    });

    test('worker exit fails every pending request and clears them', () async {
      final fake = _FakeWorker();
      addTearDown(fake.close);
      final req = fake.nextRequest();
      final future = fake.worker.runForTesting<int, int>(
        _double,
        1,
        inactivityTimeout: const Duration(seconds: 5),
      );
      await req;
      fake.worker.exitForTesting();
      await expectLater(future, throwsA(isA<DownloadException>()));
      expect(fake.worker.pendingCount, 0);
    });
  });

  group('DownloadWorker.run', () {
    test('falls back inline when the worker is disabled', () async {
      DownloadWorker.enabled = false;
      expect(await DownloadWorker.run(_double, 4), 8);
    });

    test('inline fallback forwards WorkerProgress.report to onProgress', () async {
      final seen = <Object>[];
      final r = await DownloadWorker.run(_reportsProgress, 3, onProgress: seen.add);
      expect(r, 'done');
      expect(seen, [1, 2, 3]);
    });

    test('WorkerProgress.report outside run is a no-op', () {
      expect(() => WorkerProgress.report(1), returnsNormally);
    });

    test('inline fallback propagates errors', () async {
      await expectLater(DownloadWorker.run(_boom, 0), throwsA(isA<DownloadException>()));
    });
  });

  group('worker side', () {
    test('call: runs fn after session restore, coalesces progress, replies last', () async {
      final inbox = ReceivePort();
      addTearDown(inbox.close);
      final got = <Map<String, dynamic>>[];
      final done = Completer<void>();
      inbox.listen((m) {
        final map = (m as Map).cast<String, dynamic>();
        got.add(map);
        if (map['type'] != 'progress') done.complete();
      });

      await handleRequestForTesting(
        {'type': 'call', 'id': 5, 'fn': _reportsProgress, 'arg': 50},
        inbox.sendPort,
        ensureSession: () async => true,
      );
      await done.future;

      expect(got.last, {'id': 5, 'result': 'done'});
      final progress = got.where((m) => m['type'] == 'progress').toList();
      // 50 synchronous reports: the first goes out, the rest coalesce into one
      // flushed value (the last), always before the final reply.
      expect(progress.length, 2);
      expect(progress.first['value'], 1);
      expect(progress.last['value'], 50);
      expect(got.indexOf(got.last), got.length - 1);
    });

    test('call: failing fn and missing session each produce exactly one error reply', () async {
      final inbox = ReceivePort();
      addTearDown(inbox.close);
      final got = <Map<String, dynamic>>[];
      inbox.listen((m) => got.add((m as Map).cast<String, dynamic>()));

      await handleRequestForTesting(
        {'type': 'call', 'id': 1, 'fn': _boom, 'arg': 0},
        inbox.sendPort,
        ensureSession: () async => true,
      );
      await handleRequestForTesting(
        {'type': 'call', 'id': 2, 'fn': _double, 'arg': 1},
        inbox.sendPort,
        ensureSession: () async => false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(got, [
        {'id': 1, 'error': 'kaboom'},
        {'id': 2, 'error': 'No session to restore in download isolate.'},
      ]);
    });

    test('ProgressThrottle: at most one per interval, trailing value flushed, none after close',
        () async {
      final sent = <Object>[];
      final t = ProgressThrottle(sent.add, interval: const Duration(milliseconds: 60));
      t.report(0.1);
      t.report(0.2);
      t.report(0.3);
      expect(sent, [0.1]);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sent, [0.1, 0.3]);

      t.report(0.4); // interval elapsed: immediate
      expect(sent, [0.1, 0.3, 0.4]);
      t.report(0.5);
      t.sendFinal(1.0); // drops the pending 0.5, sends the final value
      expect(sent, [0.1, 0.3, 0.4, 1.0]);
      t.sendFinal(1.0); // not repeated
      expect(sent.length, 4);

      t.report(0.6);
      t.close();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(sent.length, 4);
    });
  });

  group('withInactivityTimeout', () {
    test('completes with the value and cancels its timer', () async {
      final v = await withInactivityTimeout<int>(
        const Duration(milliseconds: 50),
        (touch) async => 3,
      );
      expect(v, 3);
      await Future<void>.delayed(const Duration(milliseconds: 100)); // no late error
    });

    test('times out, runs onTimeout once, swallows the late result', () async {
      var cleaned = 0;
      final never = Completer<int>();
      final f = withInactivityTimeout<int>(
        const Duration(milliseconds: 40),
        (touch) => never.future,
        onTimeout: () => cleaned++,
      );
      await expectLater(
        f,
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', 'timeout')),
      );
      expect(cleaned, 1);
      never.completeError(StateError('late'));
      await Future<void>.delayed(const Duration(milliseconds: 20)); // no unhandled error
      expect(cleaned, 1);
    });

    test('synchronous throw in start surfaces as an error, not a timeout', () async {
      await expectLater(
        withInactivityTimeout<int>(
          const Duration(seconds: 5),
          (touch) => throw StateError('send failed'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
