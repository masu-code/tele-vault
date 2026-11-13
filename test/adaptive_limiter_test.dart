import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/thumbnail/adaptive_limiter.dart';

/// The AIMD concurrency of the bulk thumbnail fetch: starts at 4, halves on a
/// flood gate (4 -> 2 -> 1), grows by one after 20 clean tasks (max 4), and
/// priority tasks leave the queue first.

Future<void> _runClean(AdaptiveLimiter l, int n) async {
  for (var i = 0; i < n; i++) {
    await l.run(() async {});
  }
}

void main() {
  test('starts at 4 and halves on each flood: 4 -> 2 -> 1, never below 1', () {
    final l = AdaptiveLimiter();
    expect(l.limit, 4);
    expect(l.onFlood(), 2);
    expect(l.onFlood(), 1);
    expect(l.onFlood(), 1);
    expect(l.limit, 1);
  });

  test('recovers by one per 20 consecutive successes, capped at 4', () async {
    final l = AdaptiveLimiter()
      ..onFlood()
      ..onFlood();
    await _runClean(l, 19);
    expect(l.limit, 1, reason: '19 successes are not enough');
    await _runClean(l, 1);
    expect(l.limit, 2);
    await _runClean(l, 20);
    expect(l.limit, 3);
    await _runClean(l, 20);
    expect(l.limit, 4);
    await _runClean(l, 60);
    expect(l.limit, 4, reason: 'never above max');
  });

  test('a flood resets the success streak', () async {
    final l = AdaptiveLimiter()..onFlood(); // 2
    await _runClean(l, 19);
    l.onFlood(); // 1, streak back to 0
    await _runClean(l, 19);
    expect(l.limit, 1);
    await _runClean(l, 1);
    expect(l.limit, 2);
  });

  test('a task that ran through a flood does not count as a success', () async {
    final l = AdaptiveLimiter(successesToGrow: 1)..onFlood(); // 2
    final gate = Completer<void>();
    final running = l.run(() => gate.future);
    await Future<void>.delayed(Duration.zero);
    l.onFlood(); // 1, while the task is in flight
    gate.complete();
    await running;
    expect(l.limit, 1, reason: 'that task saw a flood: no growth');
    await _runClean(l, 1);
    expect(l.limit, 2);
  });

  test('a failing task is neither a success nor a flood', () async {
    final l = AdaptiveLimiter(successesToGrow: 1)..onFlood(); // 2
    await expectLater(l.run<void>(() async => throw StateError('x')), throwsStateError);
    expect(l.limit, 2);
    expect(l.running, 0);
  });

  test('never runs more tasks at once than the current limit', () async {
    final l = AdaptiveLimiter()..onFlood(); // 2
    var active = 0;
    var peak = 0;
    await Future.wait([
      for (var i = 0; i < 10; i++)
        l.run(() async {
          peak = peak < ++active ? active : peak;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active--;
        }),
    ]);
    expect(peak, 2);
  });

  test('priority tasks start before queued background ones', () async {
    final l = AdaptiveLimiter(max: 1);
    final order = <String>[];
    final hold = Completer<void>();
    final first = l.run(() => hold.future);
    Future<void> task(String name, {bool priority = false}) =>
        l.run(() async => order.add(name), priority: priority);
    final all = [
      task('bg1'),
      task('bg2'),
      task('prio1', priority: true),
      task('bg3'),
      task('prio2', priority: true),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(order, isEmpty, reason: 'the only slot is held');
    hold.complete();
    await Future.wait([first, ...all]);
    expect(order, ['prio1', 'prio2', 'bg1', 'bg2', 'bg3']);
  });

  test('growing the limit starts queued tasks right away', () async {
    final l = AdaptiveLimiter(successesToGrow: 1)
      ..onFlood()
      ..onFlood(); // 1
    final firstHold = Completer<void>();
    final hold = Completer<void>();
    var started = 0;
    final first = l.run(() async {
      started++;
      await firstHold.future;
    });
    Future<void> queued() => l.run(() async {
          started++;
          await hold.future;
        });
    final rest = [queued(), queued()];
    await Future<void>.delayed(Duration.zero);
    expect(started, 1, reason: 'limit 1: the others wait');
    firstHold.complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(l.limit, 2);
    expect(started, 3, reason: 'one clean task grew the limit to 2: both queued start');
    hold.complete();
    await Future.wait(rest);
  });
}
