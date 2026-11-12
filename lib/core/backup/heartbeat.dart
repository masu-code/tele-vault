import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// File-based liveness markers shared by every isolate of the process (the
/// UI isolate, the transfer queue and the headless WorkManager engine).
///
/// Each marker is a tiny file (`hb_app`, `hb_queue`) holding the epoch
/// milliseconds of the last touch. Files replace the SharedPreferences keys
/// that used to be rewritten every 20 s: there is no shared cache to go stale
/// between isolates, nothing is written while idle beyond one small file per
/// [minInterval], and a reader always sees what the other isolate wrote.
class Heartbeat {
  Heartbeat._();

  /// Writes are skipped when the same isolate already touched [name] less
  /// than this long ago. Must stay well below every freshness window the
  /// readers use (45 s for the queue, 60 s for the app).
  static const minInterval = Duration(seconds: 15);

  static const _names = {'app', 'queue'};

  static String? _dir;
  static final Map<String, int> _lastWriteMs = {};

  /// Injectable clock (tests).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Sets the directory the marker files live in. Called by
  /// `BackupRegistry.init`.
  static void configure(String dir) {
    if (_dir != dir) {
      _dir = dir;
      _lastWriteMs.clear();
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _dir = null;
    _lastWriteMs.clear();
    clock = DateTime.now;
  }

  static File? _file(String name) {
    if (!_names.contains(name)) {
      throw ArgumentError.value(name, 'name', "must be 'app' or 'queue'");
    }
    final dir = _dir;
    if (dir == null) return null;
    return File('$dir${Platform.pathSeparator}hb_$name');
  }

  /// Records "alive now" for [name]. At most one write per [minInterval]
  /// from this isolate unless [force]. Never throws: a failed heartbeat must
  /// not break an upload.
  static Future<void> touch(String name, {bool force = false}) async {
    final file = _file(name);
    if (file == null) return;
    final now = clock().millisecondsSinceEpoch;
    final last = _lastWriteMs[name];
    if (!force &&
        last != null &&
        now >= last &&
        now - last < minInterval.inMilliseconds) {
      return;
    }
    _lastWriteMs[name] = now;
    try {
      // tmp + rename so a reader in another isolate never sees a half
      // written (unparseable -> "not alive") value.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString('$now', flush: false);
      await tmp.rename(file.path);
    } catch (e) {
      try {
        await file.writeAsString('$now');
      } catch (e2) {
        debugPrint('Heartbeat: touch($name) failed: ${e2.runtimeType}');
      }
    }
  }

  /// Epoch ms of the last touch of [name] by any isolate, or null.
  static int? lastMs(String name) {
    final file = _file(name);
    if (file == null) return null;
    try {
      return int.tryParse(file.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  /// True if [name] was touched within [maxAge].
  static bool isFresh(String name, Duration maxAge) {
    final last = lastMs(name);
    if (last == null) return false;
    return clock().millisecondsSinceEpoch - last < maxAge.inMilliseconds;
  }
}
