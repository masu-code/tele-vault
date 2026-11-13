import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pool/pool.dart';

import '../../models/capture_date.dart';
import '../../models/file_index.dart';
import '../../models/file_item.dart';
import '../download/download_service.dart' show DownloadException;
import '../download/download_worker.dart';
import '../telegram/client.dart' show FloodWaitException;
import '../thumbnail/backfill_service.dart' show BackfillIndexAccess;
import 'capture_date_probe.dart';

// ------------------------------------------------------------------ state

/// Results of earlier runs, so a run resumes where the last one stopped and
/// never probes an item twice. Ids and numbers only (no names or paths).
class CaptureRecoveryState {
  CaptureRecoveryState({
    Map<String, String>? done,
    Map<String, int>? dated,
    this.bytesDownloaded = 0,
    this.lastRunAt,
  })  : done = done ?? <String, String>{},
        dated = dated ?? <String, int>{};

  static const int version = 1;

  /// Item id -> result (`dated`, `noDate`, `unsupported`, `missing`). Items
  /// that failed with an error are not recorded: the next run retries them.
  final Map<String, String> done;

  /// Item id -> capture time (epoch ms) found for it. Kept after the index
  /// write too: re-applying it is a no-op (a stored `taken_at` is never
  /// overwritten), and a run killed between this file and the index write
  /// writes it on the next run.
  final Map<String, int> dated;

  int bytesDownloaded;
  DateTime? lastRunAt;

  int count(CaptureProbeStatus s) => done.values.where((v) => v == s.name).length;

  Map<String, dynamic> toJson() => {
        'v': version,
        'done': done,
        'dated': dated,
        'bytes': bytesDownloaded,
        if (lastRunAt != null) 'last_run_at': lastRunAt!.toIso8601String(),
      };

  factory CaptureRecoveryState.fromJson(Map<String, dynamic> j) => CaptureRecoveryState(
        done: {
          for (final e in ((j['done'] as Map?) ?? const {}).entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
        },
        dated: {
          for (final e in ((j['dated'] as Map?) ?? const {}).entries)
            if (e.key is String && e.value is int) e.key as String: e.value as int,
        },
        bytesDownloaded: j['bytes'] as int? ?? 0,
        lastRunAt: DateTime.tryParse(j['last_run_at'] as String? ?? ''),
      );
}

/// `capture_date_recovery.json` under app support, written atomically.
class CaptureRecoveryStateStore {
  CaptureRecoveryStateStore(this._resolveDir);

  static const String fileName = 'capture_date_recovery.json';

  final Future<Directory> Function() _resolveDir;
  Future<void> _io = Future<void>.value();

  Future<File> _file() async {
    final dir = await _resolveDir();
    await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  /// The saved state; an unreadable file starts over (items already dated
  /// in the index are not candidates again, so nothing is redone).
  Future<CaptureRecoveryState> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return CaptureRecoveryState();
      final doc = jsonDecode(await file.readAsString());
      return doc is Map<String, dynamic> && doc['v'] == CaptureRecoveryState.version
          ? CaptureRecoveryState.fromJson(doc)
          : CaptureRecoveryState();
    } catch (_) {
      return CaptureRecoveryState();
    }
  }

  Future<void> save(CaptureRecoveryState state) {
    final text = jsonEncode(state.toJson());
    final next = _io.then((_) async {
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
    });
    _io = next.catchError((Object _) {});
    return next;
  }
}

// ------------------------------------------------------------------ seams

/// Telegram reads used by the job (read-only: no upload, send or delete).
abstract class CaptureDateRemote {
  Future<List<CaptureProbeResult>> probe(List<CaptureProbeTarget> targets);
}

/// Runs [probeCaptureDates] on the download worker isolate.
class WorkerCaptureDateRemote implements CaptureDateRemote {
  const WorkerCaptureDateRemote();

  @override
  Future<List<CaptureProbeResult>> probe(List<CaptureProbeTarget> targets) async {
    final raw = await DownloadWorker.run<CaptureProbeArgs, List<Object?>>(
      probeCaptureDates,
      CaptureProbeArgs(targets),
      inactivityTimeout: const Duration(seconds: 120),
    );
    return raw.whereType<CaptureProbeResult>().toList();
  }
}

/// Something stopped the job before it did any work. Safe to show.
class CaptureRecoveryBlockedException implements Exception {
  const CaptureRecoveryBlockedException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------- plan/progress

/// What a run would do, computed from the index and the state file only
/// (no network, nothing downloaded).
@immutable
class CaptureRecoveryPlan {
  const CaptureRecoveryPlan({
    required this.candidates,
    required this.photos,
    required this.videos,
    required this.unsupported,
    required this.alreadyProcessed,
    required this.pendingWrites,
    required this.estimatedBytes,
  });

  /// Photos and videos dated by their upload time.
  final int candidates;

  /// Still to probe, by kind.
  final int photos;
  final int videos;
  final int unsupported;

  /// Probed by an earlier run (skipped).
  final int alreadyProcessed;

  /// Dates found earlier that are not in the index yet.
  final int pendingWrites;

  /// Upper bound of the bytes a run downloads.
  final int estimatedBytes;
}

enum CaptureRecoveryPhase { idle, running, paused, done, failed }

@immutable
class CaptureRecoveryProgress {
  const CaptureRecoveryProgress({
    this.phase = CaptureRecoveryPhase.idle,
    this.total = 0,
    this.processed = 0,
    this.dated = 0,
    this.noDate = 0,
    this.unsupported = 0,
    this.errors = 0,
    this.written = 0,
    this.bytesDownloaded = 0,
    this.error,
  });

  final CaptureRecoveryPhase phase;

  /// Items this run works on, and how many are finished either way.
  final int total;
  final int processed;
  final int dated;
  final int noDate;
  final int unsupported;

  /// Failed reads plus items whose message is gone.
  final int errors;

  /// Dates written to the index by this run.
  final int written;
  final int bytesDownloaded;
  final String? error;

  bool get running => phase == CaptureRecoveryPhase.running;

  CaptureRecoveryProgress copyWith({
    CaptureRecoveryPhase? phase,
    int? total,
    int? processed,
    int? dated,
    int? noDate,
    int? unsupported,
    int? errors,
    int? written,
    int? bytesDownloaded,
    String? error,
  }) =>
      CaptureRecoveryProgress(
        phase: phase ?? this.phase,
        total: total ?? this.total,
        processed: processed ?? this.processed,
        dated: dated ?? this.dated,
        noDate: noDate ?? this.noDate,
        unsupported: unsupported ?? this.unsupported,
        errors: errors ?? this.errors,
        written: written ?? this.written,
        bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
        error: error ?? this.error,
      );
}

// ---------------------------------------------------------------- service

/// One-time recovery of capture dates for cloud photos and videos that the
/// gallery dates by their upload time (no stored `taken_at`, no date in the
/// name): reads EXIF DateTimeOriginal from the first 128 KB of a JPEG, or
/// `mvhd.creation_time` of an MP4/MOV/3GP (<= 3 windows of 64 KB), and
/// stores what it finds as `taken_at`.
///
/// Read-only on Telegram except the index write through
/// [BackfillIndexAccess.write] (`IndexNotifier.applyAndSave`), done once at the
/// end of a run (also when it was paused or stopped), never in the middle: each
/// save rotates the local index backups, and the state file already holds every
/// result, so a killed run writes them on the next one without reading again.
/// Names and files are never
/// changed; an existing `taken_at` is never overwritten ([stampTakenAt]).
/// Resumable and idempotent through [CaptureRecoveryStateStore].
class CaptureDateRecoveryService {
  CaptureDateRecoveryService({
    required BackfillIndexAccess index,
    CaptureDateRemote? remote,
    CaptureRecoveryStateStore? stateStore,
    Future<bool> Function()? networkAllowed,
    bool? requireUnmetered,
    this.concurrency = 2,
    this.batchSize = 10,
    DateTime Function()? now,
  })  : _indexAccess = index,
        _remote = remote ?? const WorkerCaptureDateRemote(),
        _store = stateStore ?? CaptureRecoveryStateStore(getApplicationSupportDirectory),
        _networkAllowed = networkAllowed ?? _unmeteredNetwork,
        _requireUnmetered = requireUnmetered ?? Platform.isAndroid,
        _now = now ?? DateTime.now;

  final BackfillIndexAccess _indexAccess;
  final CaptureDateRemote _remote;
  final CaptureRecoveryStateStore _store;
  final Future<bool> Function() _networkAllowed;
  final bool _requireUnmetered;
  final DateTime Function() _now;

  /// Probe calls in flight at once.
  final int concurrency;

  /// Items per probe call (one `getMessages` + their ranged reads).
  final int batchSize;

  final ValueNotifier<CaptureRecoveryProgress> _progress =
      ValueNotifier<CaptureRecoveryProgress>(const CaptureRecoveryProgress());

  ValueListenable<CaptureRecoveryProgress> get progress => _progress;

  /// Whether Run must check for an unmetered network first (Android).
  bool get requiresUnmeteredNetwork => _requireUnmetered;

  bool _busy = false;
  bool _pauseRequested = false;
  String? _stop;

  bool get isBusy => _busy;

  /// Stops starting new batches; the next run continues where this stopped.
  void pause() {
    if (_busy) _pauseRequested = true;
  }

  /// Media items dated by their upload time: image/* or video/*, no stored
  /// `taken_at`, no date in the name.
  static List<FileItem> candidatesOf(FileIndex index) => [
        for (final f in index.files)
          if ((f.mimeType.startsWith('image/') || f.mimeType.startsWith('video/')) &&
              f.parts.isNotEmpty &&
              !hasStoredTakenAt(f) &&
              datedByUploadTime(f))
            f,
      ];

  /// Counts and the byte estimate of a run. No network.
  Future<CaptureRecoveryPlan> plan() async {
    if (_busy) throw const CaptureRecoveryBlockedException('La recuperación ya está en curso.');
    final index = _usableIndex();
    final state = await _store.load();
    final candidates = candidatesOf(index);
    var photos = 0, videos = 0, unsupported = 0, processed = 0, pending = 0, bytes = 0;
    for (final f in candidates) {
      if (state.done.containsKey(f.id)) {
        processed++;
        if (state.dated.containsKey(f.id)) pending++;
        continue;
      }
      final kind = captureKindOf(f.mimeType);
      switch (kind) {
        case CaptureKind.jpeg:
          photos++;
        case CaptureKind.mp4:
          videos++;
        case CaptureKind.unsupported:
          unsupported++;
      }
      bytes += probeByteEstimate(kind, _firstPart(f).size);
    }
    _log('plan candidates=${candidates.length} photos=$photos videos=$videos '
        'unsupported=$unsupported processed=$processed pending=$pending bytes=$bytes');
    return CaptureRecoveryPlan(
      candidates: candidates.length,
      photos: photos,
      videos: videos,
      unsupported: unsupported,
      alreadyProcessed: processed,
      pendingWrites: pending,
      estimatedBytes: bytes,
    );
  }

  /// Ids whose read failed in this process: a chunked run takes them last,
  /// so one item that keeps failing never blocks the rest.
  final Set<String> _erroredThisSession = <String>{};

  /// Probes every candidate not processed yet (at most [maxItems] of them:
  /// a small resumable chunk) and writes the dates found.
  Future<CaptureRecoveryProgress> run({int? maxItems}) async {
    if (_busy) throw const CaptureRecoveryBlockedException('La recuperación ya está en curso.');
    _busy = true;
    _pauseRequested = false;
    _stop = null;
    CaptureRecoveryState? state;
    final pending = <String, int>{};
    var writeChain = Future<void>.value();
    try {
      if (_requireUnmetered && !await _networkAllowed()) {
        throw const CaptureRecoveryBlockedException(
            'Se necesita Wi-Fi o Ethernet (una red sin límite de datos).');
      }
      final index = _usableIndex();
      final s = state = await _store.load();
      final candidates = candidatesOf(index);

      // Dates found by a run that was stopped before its index write.
      for (final f in candidates) {
        final ms = s.dated[f.id];
        if (ms != null) pending[f.id] = ms;
      }
      var todo = [for (final f in candidates) if (!s.done.containsKey(f.id)) f];
      if (maxItems != null && todo.length > maxItems) {
        todo = [
          ...todo.where((f) => !_erroredThisSession.contains(f.id)),
          ...todo.where((f) => _erroredThisSession.contains(f.id)),
        ].sublist(0, maxItems);
      }
      _set(CaptureRecoveryProgress(phase: CaptureRecoveryPhase.running, total: todo.length));
      _log('run candidates=${candidates.length} todo=${todo.length} pending=${pending.length}');

      Future<void> flush() {
        if (pending.isEmpty) return writeChain;
        final batch = Map<String, int>.of(pending);
        pending.clear();
        final next = writeChain.then((_) async {
          await _store.save(s);
          await _indexAccess.write((current) => stampTakenAt(current, batch));
          _set(_progress.value.copyWith(written: _progress.value.written + batch.length));
          _log('wrote dates=${batch.length}');
        });
        writeChain = next.catchError((Object _) {});
        return next;
      }

      // Unsupported formats are settled without any download.
      final targets = <CaptureProbeTarget>[];
      for (final f in todo) {
        final kind = captureKindOf(f.mimeType);
        if (kind == CaptureKind.unsupported) {
          _record(s, CaptureProbeResult(f.id, CaptureProbeStatus.unsupported), pending);
        } else {
          targets.add(CaptureProbeTarget(f.id, _firstPart(f).messageId, kind,
              multiPart: f.parts.length > 1));
        }
      }

      var batchFailures = 0;
      final pool = Pool(concurrency);
      try {
        await Future.wait([
          for (var i = 0; i < targets.length; i += batchSize)
            pool.withResource(() async {
              if (_pauseRequested || _stop != null) return;
              final batch = targets.sublist(i, math.min(i + batchSize, targets.length));
              List<CaptureProbeResult> results;
              try {
                results = await _remote.probe(batch);
                batchFailures = 0;
              } catch (e) {
                if (_isFloodWait(e)) {
                  _stop = 'Telegram pidió esperar; ejecuta de nuevo más tarde para continuar.';
                } else if (++batchFailures >= 3) {
                  _stop = 'Varias lecturas fallaron seguidas; ejecuta de nuevo para continuar.';
                }
                _log('batch failed: ${e.runtimeType}');
                results = [
                  for (final t in batch) CaptureProbeResult(t.id, CaptureProbeStatus.error),
                ];
              }
              final byId = {for (final r in results) r.id: r};
              for (final t in batch) {
                final r = byId[t.id] ?? CaptureProbeResult(t.id, CaptureProbeStatus.error);
                _record(s, r, pending);
              }
              await _store.save(s);
            }),
        ]);
      } finally {
        await pool.close();
      }

      await flush();
      await writeChain;
      final paused = _pauseRequested;
      final stop = _stop;
      s.lastRunAt = _now().toUtc();
      await _store.save(s);
      final p = _progress.value;
      _log('run ${stop != null ? 'stopped' : paused ? 'paused' : 'done'} dated=${p.dated} '
          'noDate=${p.noDate} unsupported=${p.unsupported} errors=${p.errors} '
          'written=${p.written} bytes=${p.bytesDownloaded}');
      _set(p.copyWith(
        phase: stop != null || paused ? CaptureRecoveryPhase.paused : CaptureRecoveryPhase.done,
        error: stop,
      ));
      return _progress.value;
    } catch (e) {
      final s = state;
      if (s != null) {
        try {
          await writeChain;
          s.lastRunAt = _now().toUtc();
          await _store.save(s);
        } catch (_) {}
      }
      _log('run failed: ${e.runtimeType}');
      _set(_progress.value.copyWith(phase: CaptureRecoveryPhase.failed, error: _safeMessage(e)));
      rethrow;
    } finally {
      _busy = false;
      _pauseRequested = false;
    }
  }

  /// Records [r] in [s] and the progress; returns true when it found a date
  /// (added to [pending]). Errors are not recorded, so they are retried.
  bool _record(CaptureRecoveryState s, CaptureProbeResult r, Map<String, int> pending) {
    var p = _progress.value.copyWith(
      processed: _progress.value.processed + 1,
      bytesDownloaded: _progress.value.bytesDownloaded + r.bytes,
    );
    s.bytesDownloaded += r.bytes;
    var found = false;
    final ms = r.ms;
    switch (r.status) {
      case CaptureProbeStatus.dated when ms != null && plausibleCaptureMs(ms) != null:
        s.done[r.id] = CaptureProbeStatus.dated.name;
        s.dated[r.id] = ms;
        pending[r.id] = ms;
        p = p.copyWith(dated: p.dated + 1);
        found = true;
      case CaptureProbeStatus.dated:
      case CaptureProbeStatus.noDate:
        s.done[r.id] = CaptureProbeStatus.noDate.name;
        p = p.copyWith(noDate: p.noDate + 1);
      case CaptureProbeStatus.unsupported:
        s.done[r.id] = CaptureProbeStatus.unsupported.name;
        p = p.copyWith(unsupported: p.unsupported + 1);
      case CaptureProbeStatus.missing:
        s.done[r.id] = CaptureProbeStatus.missing.name;
        p = p.copyWith(errors: p.errors + 1);
      case CaptureProbeStatus.error:
        _erroredThisSession.add(r.id);
        p = p.copyWith(errors: p.errors + 1);
    }
    _set(p);
    return found;
  }

  FileIndex _usableIndex() {
    final index = _indexAccess.current();
    if (index == null) {
      throw const CaptureRecoveryBlockedException(
          'El índice se está cargando o guardando; inténtalo de nuevo en un momento.');
    }
    return index;
  }

  void _set(CaptureRecoveryProgress value) => _progress.value = value;

  static _FirstPart _firstPart(FileItem f) {
    var best = f.parts.first;
    for (final part in f.parts) {
      if (part.part < best.part) best = part;
    }
    return (messageId: best.messageId, size: best.size);
  }

  static bool _isFloodWait(Object e) {
    if (e is FloodWaitException) return true;
    final text = e is DownloadException ? e.message : e.toString();
    return FloodWaitException.tryParse(text) != null;
  }

  /// Exception text that is safe to show (never a file name or path).
  static String _safeMessage(Object e) => switch (e) {
        CaptureRecoveryBlockedException(:final message) => message,
        _ => 'La recuperación se detuvo (${e.runtimeType}). Ejecútala de nuevo para continuar.',
      };

  static void _log(String message) => debugPrint('TVDIAG: capture-dates $message');

  static Future<bool> _unmeteredNetwork() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }
}

/// The first part's message and size.
typedef _FirstPart = ({int messageId, int size});
