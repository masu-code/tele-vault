import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tv_core/models.dart' show FileIndex;

import '../index/index_service.dart';
import '../metadata/capture_date_recovery.dart';
import 'auto_pack_service.dart';
import 'backfill_service.dart';

// --------------------------------------------------------------------- lock

/// One maintenance job at a time across the app isolate and the headless
/// WorkManager engines: a small file holding `<token> <epoch ms>`, refreshed
/// while held and considered abandoned after [staleAfter] (a killed process
/// never blocks the next run for long).
class MaintenanceLock {
  MaintenanceLock(this._resolveFile, {this.staleAfter = const Duration(minutes: 3), DateTime Function()? now})
      : _now = now ?? DateTime.now,
        _token = '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 32)}';

  /// The lock file under app support (`tv_maintenance.lock`).
  factory MaintenanceLock.standard() => MaintenanceLock(() async {
        final support = await getApplicationSupportDirectory();
        return File(p.join(support.path, 'tv_maintenance.lock'));
      });

  final Future<File> Function() _resolveFile;
  final Duration staleAfter;
  final DateTime Function() _now;
  final String _token;
  bool _held = false;

  bool get isHeld => _held;

  /// Takes the lock unless someone else holds a fresh one. The file is
  /// created with `create(exclusive: true)`, which the OS makes atomic: of
  /// several engines racing for a free lock exactly one creates it. A stale
  /// lock (older than [staleAfter]) is deleted and the create retried once.
  /// Never throws.
  Future<bool> tryAcquire() async {
    try {
      final file = await _resolveFile();
      await file.parent.create(recursive: true);
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await file.create(exclusive: true);
          try {
            await file.writeAsString('$_token ${_now().millisecondsSinceEpoch}', flush: true);
          } catch (_) {
            try {
              await file.delete();
            } catch (_) {}
            return false;
          }
          return _held = true;
        } on FileSystemException {
          // Already exists: whose is it?
        }
        final other = await _read(file);
        if (other != null && other.token == _token) {
          await _write(file);
          return _held = true;
        }
        // A file that is empty or unreadable (its creator is between create
        // and write, or died there) ages by its modification time.
        final stale = other != null ? _isStale(other.ms) : await _unreadableIsStale(file);
        if (!stale) return false;
        try {
          // Another engine may have taken the stale lock over meanwhile: only
          // delete what we judged stale.
          final again = await _read(file);
          if (again?.token != other?.token || again?.ms != other?.ms) {
            if (again != null) return false;
            continue;
          }
          await file.delete();
        } catch (_) {
          return false;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _unreadableIsStale(File file) async {
    try {
      return _isStale((await file.lastModified()).millisecondsSinceEpoch);
    } catch (_) {
      return false;
    }
  }

  /// Keeps a held lock fresh (call well within [staleAfter]).
  Future<void> refresh() async {
    if (!_held) return;
    try {
      final file = await _resolveFile();
      final cur = await _read(file);
      if (cur != null && cur.token != _token) {
        _held = false;
        return;
      }
      await _write(file);
    } catch (_) {}
  }

  Future<void> release() async {
    if (!_held) return;
    _held = false;
    try {
      final file = await _resolveFile();
      final cur = await _read(file);
      if (cur != null && cur.token == _token) await file.delete();
    } catch (_) {}
  }

  bool _isStale(int ms) {
    final age = _now().millisecondsSinceEpoch - ms;
    return age < 0 || age > staleAfter.inMilliseconds;
  }

  Future<({String token, int ms})?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      final parts = (await file.readAsString()).trim().split(' ');
      if (parts.length != 2) return null;
      final ms = int.tryParse(parts[1]);
      return ms == null ? null : (token: parts[0], ms: ms);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(File file) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.$_token.tmp');
    await tmp.writeAsString('$_token ${_now().millisecondsSinceEpoch}', flush: true);
    await tmp.rename(file.path);
  }
}

// ------------------------------------------------------------- index access

/// [BackfillIndexAccess] over [IndexService] for the headless engine (no
/// Riverpod there): every write reloads the index, applies the mutation and
/// saves it through `IndexService.save` (backup, conditional write, rebase
/// and read-back), keeping the index that was written.
class IndexServiceAccess implements BackfillIndexAccess {
  IndexServiceAccess(this._service);

  final IndexService _service;
  FileIndex? _index;

  /// Loads the index once; [current] stays null if that fails.
  Future<bool> load() async {
    try {
      _index = await _service.load();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  FileIndex? current() => _index;

  @override
  Future<FileIndex> write(FileIndex Function(FileIndex current) mutate) async {
    final fresh = await _service.load();
    final next = mutate(fresh);
    if (identical(next, fresh)) return _index = fresh;
    return _index = await _service.save(next);
  }
}

// ------------------------------------------------------------------ service

enum MaintenanceStep { idle, packing, dates, backfill }

/// What the maintenance job is doing, for a read-only status line. Counts
/// only.
@immutable
class MaintenanceStatus {
  const MaintenanceStatus({this.step = MaintenanceStep.idle, this.handled = 0});
  final MaintenanceStep step;

  /// Items handled by this run so far (packed thumbnails, probed dates,
  /// backfilled items).
  final int handled;

  bool get running => step != MaintenanceStep.idle;
}

/// What one [AutoMaintenanceService.runOnce] did. Counts only.
@immutable
class MaintenanceReport {
  const MaintenanceReport({
    this.skipped,
    this.packs = 0,
    this.packedThumbs = 0,
    this.datesProcessed = 0,
    this.backfillChunks = 0,
    this.backfillProduced = 0,
  });

  /// Why nothing ran (`busy`, `metered`, `locked`, `running`), or null.
  final String? skipped;
  final int packs;
  final int packedThumbs;
  final int datesProcessed;
  final int backfillChunks;
  final int backfillProduced;
}

/// The automatic background maintenance: no button, the app finds the work
/// and does it in small resumable steps.
///
/// 1. Auto-pack local thumbnails no pack covers ([AutoPackService]):
///    unmetered network.
/// 2. Capture-date recovery in chunks of [datesChunk] items (a few KB per
///    file, one index write per chunk): unmetered network.
/// 3. Thumbnail backfill of old items with no thumbnail at all, in chunks of
///    [backfillChunk] candidates (it downloads originals): unmetered network
///    AND charging AND no user work, at most [maxBackfillChunks] per run and
///    within [budget].
///
/// Nothing runs while the user is busy ([userBusy]: an upload queue run,
/// thumbnails on screen still loading) unless the queue run just finished,
/// and only one job runs at a time across the app and the headless engine
/// ([MaintenanceLock]). Telegram writes: pack `sendMedia` and index saves.
class AutoMaintenanceService {
  AutoMaintenanceService({
    required this.packer,
    required this.dates,
    required this.backfill,
    required this.lock,
    required this.unmetered,
    required this.charging,
    required this.userBusy,
    this.datesChunk = 200,
    this.backfillChunk = 50,
    this.maxBackfillChunks = 1,
    this.budget = const Duration(minutes: 8),
    this.lockRefreshEvery = const Duration(seconds: 30),
  });

  final AutoPackService packer;
  final CaptureDateRecoveryService dates;
  final BackfillService backfill;
  final MaintenanceLock lock;

  /// Wi-Fi or Ethernet.
  final Future<bool> Function() unmetered;

  /// The device is charging (or no battery rule applies).
  final Future<bool> Function() charging;

  /// The user is doing something that goes first (upload queue, thumbnails
  /// on screen).
  final bool Function() userBusy;

  final int datesChunk;
  final int backfillChunk;
  final int maxBackfillChunks;
  final Duration budget;
  final Duration lockRefreshEvery;

  final ValueNotifier<MaintenanceStatus> _status =
      ValueNotifier<MaintenanceStatus>(const MaintenanceStatus());

  ValueListenable<MaintenanceStatus> get status => _status;

  bool _running = false;
  bool _stopRequested = false;

  bool get isRunning => _running;

  /// Stops at the next step boundary (the OS stopped the task, the app
  /// opened); work done so far is kept and resumes next run.
  void stop() {
    if (!_running) return;
    _stopRequested = true;
    backfill.pause();
    dates.pause();
  }

  Future<MaintenanceReport> runOnce({bool queueJustFinished = false}) async {
    if (_running) return const MaintenanceReport(skipped: 'running');
    if (!queueJustFinished && userBusy()) return const MaintenanceReport(skipped: 'busy');
    if (!await _safe(unmetered)) return const MaintenanceReport(skipped: 'metered');
    if (!await lock.tryAcquire()) return const MaintenanceReport(skipped: 'locked');
    _running = true;
    _stopRequested = false;
    final refresh = Timer.periodic(lockRefreshEvery, (_) => unawaited(lock.refresh()));
    final clock = Stopwatch()..start();
    var packs = 0, packedThumbs = 0, datesProcessed = 0, chunks = 0, produced = 0;
    var handled = 0;
    void show(MaintenanceStep step) => _status.value = MaintenanceStatus(step: step, handled: handled);
    try {
      // 1. Packs from what the device already has: no download.
      show(MaintenanceStep.packing);
      try {
        final r = await packer.run();
        packs = r.packs;
        packedThumbs = r.packedThumbs;
        handled += packedThumbs;
      } catch (e) {
        _log('pack step failed: ${e.runtimeType}');
      }

      // 2. Capture dates, one small chunk.
      if (!_stopRequested && (queueJustFinished || !userBusy())) {
        show(MaintenanceStep.dates);
        try {
          final r = await dates.run(maxItems: datesChunk);
          datesProcessed = r.processed;
          handled += datesProcessed;
        } catch (e) {
          _log('dates step failed: ${e.runtimeType}');
        }
      }

      // 3. Backfill: downloads originals, so charging and idle too.
      while (chunks < maxBackfillChunks &&
          !_stopRequested &&
          clock.elapsed < budget &&
          !userBusy() &&
          await _safe(charging) &&
          await _safe(unmetered)) {
        show(MaintenanceStep.backfill);
        try {
          final r = await backfill.run(maxCandidates: backfillChunk);
          chunks++;
          produced += r.produced;
          handled += r.produced;
          if (!r.more || r.paused) break;
        } catch (e) {
          _log('backfill step failed: ${e.runtimeType}');
          break;
        }
      }
      _log('run packs=$packs thumbs=$packedThumbs dates=$datesProcessed '
          'backfillChunks=$chunks produced=$produced');
      return MaintenanceReport(
        packs: packs,
        packedThumbs: packedThumbs,
        datesProcessed: datesProcessed,
        backfillChunks: chunks,
        backfillProduced: produced,
      );
    } finally {
      refresh.cancel();
      await lock.release();
      _running = false;
      _stopRequested = false;
      _status.value = const MaintenanceStatus();
    }
  }

  static Future<bool> _safe(Future<bool> Function() check) async {
    try {
      return await check();
    } catch (_) {
      return false;
    }
  }

  static void _log(String message) => debugPrint('TVDIAG: maintenance $message');
}

/// Wi-Fi or Ethernet (an unmetered network), the backfill's own rule.
Future<bool> unmeteredNetwork() async {
  try {
    final r = await Connectivity().checkConnectivity();
    return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
  } catch (_) {
    return false;
  }
}

// ----------------------------------------------------------------- triggers

/// Coalesces maintenance triggers in the app: a trigger starts a run after
/// [delay] (thumbnails on screen go first), several triggers meanwhile make
/// one run, and a run skipped because the user was busy or another job held
/// the lock is retried once after [retryAfter].
class MaintenanceScheduler {
  MaintenanceScheduler(
    this._run, {
    this.delay = const Duration(seconds: 20),
    this.retryAfter = const Duration(minutes: 10),
  });

  final Future<MaintenanceReport> Function({bool queueJustFinished}) _run;
  final Duration delay;
  final Duration retryAfter;

  Timer? _timer;
  bool _queueJustFinished = false;
  bool _disposed = false;

  void trigger({bool queueJustFinished = false}) {
    if (_disposed) return;
    _queueJustFinished = _queueJustFinished || queueJustFinished;
    _timer?.cancel();
    _timer = Timer(delay, _fire);
  }

  Future<void> _fire() async {
    _timer = null;
    final justFinished = _queueJustFinished;
    _queueJustFinished = false;
    MaintenanceReport r;
    try {
      r = await _run(queueJustFinished: justFinished);
    } catch (_) {
      return;
    }
    final skipped = r.skipped;
    if ((skipped == 'busy' || skipped == 'locked') && _timer == null && !_disposed) {
      _timer = Timer(retryAfter, _fire);
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// Process-wide hook the transfer queue calls when a run finishes; the app's
/// maintenance binding registers the handler (a no-op until it does, so the
/// queue never builds the maintenance services itself).
abstract final class MaintenanceTriggers {
  static void Function({bool queueJustFinished})? _handler;

  static void register(void Function({bool queueJustFinished})? handler) => _handler = handler;

  static void queueFinished() => _handler?.call(queueJustFinished: true);
}
