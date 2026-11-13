import 'dart:async';

import 'package:tele_vault/core/telegram/client.dart';

/// A fake clock for the shared flood gate of [TelegramService]: no jitter, and
/// a wait "sleeps" by moving the clock, so a test sees the gate open exactly
/// when the real one would, without waiting. Every wait is appended to [waits].
class FakeFloodTime {
  FakeFloodTime(this.waits);

  final List<Duration> waits;
  DateTime now = DateTime.utc(2026, 1, 1);

  /// While set, every wait stays pending until it completes (then the clock
  /// moves), so a test can look at the world while the gate is closed.
  Completer<void>? hold;

  void install(TelegramService svc) {
    svc.debugResetFloodGate();
    svc.debugClock = () => now;
    svc.debugFloodJitter = () => Duration.zero;
    svc.debugFloodWaitDelay = delay;
  }

  static void uninstall(TelegramService svc) {
    svc.debugResetFloodGate();
    svc.debugClock = null;
    svc.debugFloodJitter = null;
    svc.debugFloodWaitDelay = null;
  }

  Future<void> delay(Duration d) async {
    waits.add(d);
    final target = now.add(d);
    await (hold?.future ?? Future<void>.delayed(Duration.zero));
    if (now.isBefore(target)) now = target;
  }
}
