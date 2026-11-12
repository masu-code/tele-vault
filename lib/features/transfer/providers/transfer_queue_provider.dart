import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:tv_core/codecs.dart' show PreviewCodec;
import '../../../core/backup/background_execution_service.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../core/thumbnail/thumb_prefetcher.dart' show defaultPreviewFromJpeg;
import '../../../core/index/index_service.dart' show IndexException;
import '../../../core/upload/upload_service.dart'
    show
        FinishedUpload,
        assetTakenAtMs,
        finishedUploadFromRow,
        indexPendingUploads,
        logSafeError,
        pendingItemJson,
        rememberUploadedThumb,
        uploadThumbFor;
import '../../../core/upload/upload_worker.dart';
import '../../../models/file_item.dart';
import '../../auth/providers/auth_provider.dart';
import '../../explorer/providers/index_provider.dart';

enum TransferKind { upload, download }

/// Aggregate progress of the background transfer queue. Only the progress
/// banner watches this — never the gallery/album grids — so per-item updates
/// don't rebuild the whole feed.
class TransferState {
  const TransferState({
    this.active = false,
    this.kind = TransferKind.upload,
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.currentName,
    this.currentProgress = 0,
    this.canceling = false,
  });

  final bool active;
  final TransferKind kind;
  final int total;
  final int done;
  final int failed;
  final String? currentName;
  /// 0..1 of the file in flight. Reset to 0 together with every [done]
  /// increment: the notification bar draws (done + currentProgress) / total,
  /// so a finished file's leftover 1.0 would count it twice until the next
  /// one started.
  final double currentProgress;
  final bool canceling;

  double get fraction => total == 0 ? 0 : done / total;

  TransferState copyWith({
    bool? active,
    TransferKind? kind,
    int? total,
    int? done,
    int? failed,
    String? currentName,
    double? currentProgress,
    bool? canceling,
  }) =>
      TransferState(
        active: active ?? this.active,
        kind: kind ?? this.kind,
        total: total ?? this.total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        currentName: currentName ?? this.currentName,
        currentProgress: currentProgress ?? this.currentProgress,
        canceling: canceling ?? this.canceling,
      );
}

/// A single background worker that uploads device assets and downloads cloud
/// files one at a time, batching index writes so a large bulk upload doesn't
/// fire hundreds of Telegram index round-trips (and hundreds of feed
/// rebuilds) — the cause of the earlier ANR/crash.
/// Uploads [file] (the original of [asset]) and returns its [FileItem]; the
/// queue's default generates the preview and runs [UploadWorker].
typedef QueueAssetUpload = Future<FileItem> Function(
  AssetEntity asset,
  File file,
  void Function(double progress) onProgress,
);

class TransferQueueNotifier extends StateNotifier<TransferState> {
  TransferQueueNotifier(
    this._ref, {
    BackupRegistry? registry,
    @visibleForTesting Future<File?> Function(AssetEntity asset)? originFile,
    @visibleForTesting QueueAssetUpload? uploadAsset,
    @visibleForTesting Duration? indexFailureBackoff,
  })  : _registry = registry ?? BackupRegistry.instance,
        _originFile = originFile ?? _defaultOriginFile,
        _uploadAsset = uploadAsset ?? _defaultUploadAsset,
        _flushFailureBackoff = indexFailureBackoff ?? flushFailureBackoff,
        super(const TransferState()) {
    // Uploads held back by [_indexNotLoaded] resume as soon as a load (the
    // resume retry, a pull to refresh) reaches Telegram.
    _ref.listen<IndexState>(indexProvider, (_, next) {
      if (_waitingForIndex &&
          !_running &&
          !next.isLoading &&
          _uploads.isNotEmpty &&
          _ref.read(indexProvider.notifier).remoteSynced) {
        _ensureRunning();
      }
    });
  }

  final Ref _ref;
  final BackupRegistry _registry;
  final Future<File?> Function(AssetEntity asset) _originFile;
  final QueueAssetUpload _uploadAsset;

  static Future<File?> _defaultOriginFile(AssetEntity asset) => asset.originFile;

  static Future<FileItem> _defaultUploadAsset(
    AssetEntity asset,
    File file,
    void Function(double progress) onProgress,
  ) async {
    // Generated here, not in the worker: the platform thumbnailer needs the
    // AssetEntity. Null (no preview) on any failure.
    final thumb = await uploadThumbFor(asset);
    // The tiny placeholder, from the same thumb, decoded by the engine to
    // <= 32 px on this isolate (no full-size decode).
    final hash = thumb == null ? null : await defaultPreviewFromJpeg(thumb);
    final item = await UploadWorker.instance.uploadFile(
      file.path,
      onProgress: onProgress,
      thumbJpeg: thumb,
      preview: hash == null ? null : PreviewCodec.toWire(hash),
      takenAtMs: assetTakenAtMs(asset),
    );
    await rememberUploadedThumb(item.id, thumbJpeg: thumb, previewHash: hash);
    return item;
  }

  /// After a failed index write the device sync waits at least this long
  /// before re-scanning (see [syncBackoffRemaining]); a longer FLOOD_WAIT
  /// extends it to that wait.
  static const flushFailureBackoff = Duration(seconds: 60);

  /// [flushFailureBackoff], or a test's shorter one.
  final Duration _flushFailureBackoff;

  DateTime? _syncBackoffUntil;

  /// The one [retryPendingIndex] scheduled for the end of the backoff after
  /// a failed index write, so the rows are written without waiting for a new
  /// photo or a network change. Replaced by each failure, cancelled on
  /// [dispose].
  Timer? _indexRetry;

  /// A [retryPendingIndex] arrived while a run was going: run once more when
  /// it ends (its own index write may already be behind it).
  bool _retryWhenIdle = false;

  @override
  void dispose() {
    _indexRetry?.cancel();
    _indexRetry = null;
    super.dispose();
  }

  /// How long the device sync (BackupNotifier) should still hold off after
  /// the last failed index write; zero when it may run.
  Duration get syncBackoffRemaining {
    final until = _syncBackoffUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left > Duration.zero ? left : Duration.zero;
  }

  void _noteIndexWriteFailure(Object e) {
    final flood = e is IndexException ? e.floodWaitSeconds : null;
    var wait = _flushFailureBackoff;
    if (flood != null && flood + 1 > wait.inSeconds) wait = Duration(seconds: flood + 1);
    _syncBackoffUntil = DateTime.now().add(wait);
    _indexRetry?.cancel();
    _indexRetry = Timer(wait, () {
      _indexRetry = null;
      if (mounted) retryPendingIndex();
    });
  }

  /// An index error for the log: its FLOOD_WAIT or its type, never a message
  /// that could quote index content.
  static String _indexErrorForLog(Object e) {
    final flood = e is IndexException ? e.floodWaitSeconds : null;
    return flood != null ? 'FLOOD_WAIT_$flood' : '${e.runtimeType}';
  }

  /// Starts a run (when idle) whose first step indexes the uploads still
  /// waiting for their index write — the device sync calls this when it has
  /// nothing new to enqueue but such uploads exist.
  void retryPendingIndex() {
    if (state.canceling) return;
    if (_running) {
      _retryWhenIdle = true;
      return;
    }
    _ensureRunning();
  }

  /// Shown while uploads are held because the vault index could not be read
  /// from Telegram yet (see [_process]).
  static const indexNotLoadedNotice =
      'Waiting for the vault index to load. Uploads resume once it does.';

  /// True while the queued uploads are held by [indexNotLoadedNotice].
  bool _waitingForIndex = false;

  /// Uploads still queued (tests).
  @visibleForTesting
  int get queuedUploads => _uploads.length;

  /// How many uploads to accumulate before writing them to the index (and
  /// refreshing the feed) in one go.
  static const _flushEvery = 8;

  final List<AssetEntity> _uploads = [];

  /// Ids of every upload from enqueue until it is fully settled (failed, skipped
  /// as already in the vault, or its index write flushed) — see [enqueueUploads].
  final Set<String> _active = {};
  final List<FileItem> _downloads = [];
  bool _running = false;

  /// Consecutive AUTH_KEY_UNREGISTERED failures across *different* items —
  /// UploadWorker/DownloadService already retry-and-reconnect within a
  /// single item before giving up, so if it's still failing by the time the
  /// exception reaches here, reconnecting again for the next item won't
  /// help either: it's the same dead key every time. Once several different
  /// items in a row all hit this, the session is genuinely revoked (e.g. by
  /// Telegram itself, or logged out from another device) rather than a
  /// transient blip — only a fresh login can recover from that, so stop
  /// hammering it and send the user back to the login screen.
  int _consecutiveAuthKeyDead = 0;
  static const _authKeyDeadThreshold = 5;

  /// Rebuilding the gallery feed re-merges/re-sorts every device asset
  /// against the cloud index — cheap once, but during a mass upload it was
  /// firing every [_flushEvery] files (a periodic hitch on top of whatever
  /// jank the upload work itself caused). Gate it to at most once per
  /// [_bumpInterval] while a batch is running; [_maybeBump] is always called
  /// with `force: true` once the queue actually empties, so the final state
  /// is never stale.
  DateTime? _lastBump;
  static const _bumpInterval = Duration(seconds: 15);

  /// Worker progress arrives per 512 KB part; the state (and every listener)
  /// is updated at most this often. A file's start and end always reset it.
  static const _progressInterval = Duration(milliseconds: 250);
  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);

  void _onProgress(double progress) {
    final now = DateTime.now();
    if (now.difference(_lastProgress) < _progressInterval) return;
    _lastProgress = now;
    state = state.copyWith(currentProgress: progress);
  }

  /// Tracks [e] against [_consecutiveAuthKeyDead] and, once the threshold is
  /// hit, invalidates the session and reports that the queue should stop.
  bool _noteFailure(Object e) {
    if (e.toString().contains('AUTH_KEY_UNREGISTERED')) {
      _consecutiveAuthKeyDead++;
      if (_consecutiveAuthKeyDead >= _authKeyDeadThreshold) {
        debugPrint('TVQUEUE: session appears dead after $_consecutiveAuthKeyDead '
            'consecutive AUTH_KEY_UNREGISTERED failures — logging out');
        unawaited(_ref.read(authProvider.notifier).invalidateSession());
        return true;
      }
    } else {
      _consecutiveAuthKeyDead = 0;
    }
    return false;
  }

  void _maybeBump({bool force = false}) {
    final now = DateTime.now();
    if (!force && _lastBump != null && now.difference(_lastBump!) < _bumpInterval) {
      return;
    }
    _lastBump = now;
    bumpDeviceState(_ref);
  }

  void enqueueUploads(List<AssetEntity> assets) {
    if (assets.isEmpty) return;
    // Not just what's still waiting in [_uploads]: an asset that has left the
    // queue but is mid-upload, or uploaded and waiting for the next index
    // flush, isn't in the registry yet either — the album watcher re-enqueued
    // it in that gap and the same file (a 700 MB video, once) went up twice.
    final queued = {..._uploads.map((a) => a.id), ..._active};
    final fresh = assets.where((a) => queued.add(a.id)).toList();
    if (fresh.isEmpty) {
      // Re-enqueueing what is held for the index retries the load.
      if (_waitingForIndex && _uploads.isNotEmpty) _ensureRunning();
      return;
    }
    _active.addAll(fresh.map((a) => a.id));
    _uploads.addAll(fresh);
    state = state.copyWith(active: true, total: state.total + fresh.length);
    _ensureRunning();
  }

  void enqueueDownloads(List<FileItem> files) {
    if (files.isEmpty) return;
    _downloads.addAll(files);
    state = state.copyWith(active: true, total: state.total + files.length);
    _ensureRunning();
  }

  void cancel() {
    state = state.copyWith(canceling: true);
    _uploads.clear();
    _active.clear();
    _downloads.clear();
    if (!_running) {
      // Nothing is running to settle the state (uploads held for the index).
      _waitingForIndex = false;
      state = const TransferState();
      unawaited(BackgroundExecutionService.instance.disable());
    }
  }

  void _ensureRunning() {
    if (_running) return;
    _running = true;
    // Keep the app's network alive while there's real transfer work queued —
    // without this, backgrounding mid-upload (screen off, another app in
    // front) lets Android/MIUI cut the connection, which in practice
    // corrupted the Telegram session outright rather than just pausing.
    unawaited(BackgroundExecutionService.instance.enable());
    _process();
  }

  Future<void> _process() async {
    // This run indexes the pending rows first: an earlier retry request is
    // covered by it.
    _retryWhenIdle = false;
    final registry = _registry;
    await registry.init();
    // Pull what the headless engine wrote since this isolate last looked, so
    // its uploads are not repeated here.
    await registry.reload();

    // Set when the uploads are held because the index is not loaded.
    var heldForIndex = false;
    try {
      // Buffer of successfully-uploaded items waiting to be written to the
      // index in one batch. Each is also a pending-index row in the registry
      // (written right after its upload), unless that write failed: those
      // ids are in [unsaved].
      final pending = <FinishedUpload>[];
      final unsaved = <String>{};

      // Writes [extra] plus every pending-index row (this run's, and those a
      // failed write of an earlier run or of the headless engine left) to the
      // index; links and clears what the written index holds. A failure keeps
      // the rows (nothing is uploaded again for them) and holds the device
      // sync off for a while. Returns whether the write succeeded.
      Future<bool> indexPending({List<FinishedUpload> extra = const []}) async {
        final uploads = [...extra];
        try {
          for (final row in await registry.pendingIndex()) {
            final u = finishedUploadFromRow(row);
            if (u != null) uploads.add(u);
          }
        } catch (e) {
          debugPrint('TVQUEUE: pending-index rows unreadable (${e.runtimeType})');
        }
        if (uploads.isEmpty) return true;
        final count = {for (final u in uploads) u.item.id}.length;
        final notifier = _ref.read(indexProvider.notifier);
        try {
          final r = await indexPendingUploads(
            uploads: uploads,
            save: (addMissing) async {
              var dropped = const <String>[];
              final written = await notifier.applyAndSave(
                addMissing,
                onDropped: (ids) => dropped = ids,
              );
              return (index: written, dropped: dropped);
            },
            commitUploads: registry.commitUploads,
            unlinkFileItem: registry.unlinkFileItem,
            removePending: registry.removePendingIndex,
          );
          unsaved.removeAll(r.settled);
          debugPrint('TVQUEUE: indexed ${r.settled.length} of $count uploaded file(s)');
          return true;
        } catch (e) {
          _noteIndexWriteFailure(e);
          debugPrint('TVQUEUE: index write failed (${_indexErrorForLog(e)}), '
              '$count uploaded file(s) stay pending, sync held '
              '${syncBackoffRemaining.inSeconds}s');
          return false;
        }
      }

      Future<void> flush() async {
        if (pending.isEmpty) return;
        final batch = List.of(pending);
        final ok = await indexPending(extra: batch);
        // Not persisted yet: counted as failed, as before. They are not
        // uploaded again (their rows keep them out), the next write retries.
        if (!ok) state = state.copyWith(failed: state.failed + batch.length);
        for (final p in batch) {
          // Without a row, only this buffer remembers the upload: keep it
          // (and its asset active) for the next flush of this run.
          if (!ok && unsaved.contains(p.item.id)) continue;
          pending.remove(p);
          _active.remove(p.assetId);
        }
        _maybeBump();
      }

      // Uploads a failed index write left behind are written first, before
      // anything new goes up.
      await indexPending();

      // --- Uploads ---
      // Every upload is deduped against the index (findUpload below). An
      // index that was never read from Telegram this session (the first load
      // failed, or is still in flight) is the device cache or empty, and
      // after a reinstall that re-uploaded the whole album. Wait for a load
      // in flight, or run one; if the index still could not be read, hold
      // the uploads (still queued, nothing marked) instead of uploading blind.
      _waitingForIndex = false;
      if (_uploads.isNotEmpty && !state.canceling) {
        final loaded =
            await _ref.read(indexProvider.notifier).ensureRemoteLoaded();
        if (!loaded) {
          heldForIndex = true;
          debugPrint('TVQUEUE: index not loaded, holding ${_uploads.length} upload(s)');
        }
      }
      while (!heldForIndex && _uploads.isNotEmpty && !state.canceling) {
        // Tells the headless periodic background task (see
        // headless_sync.dart) this process already has an upload connection
        // open, so it skips its own run instead of opening a second one.
        unawaited(registry.markQueueHeartbeat());
        final asset = _uploads.removeAt(0);
        _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
        state = state.copyWith(
          kind: TransferKind.upload,
          currentName: asset.title ?? 'Uploading…',
          currentProgress: 0,
        );
        try {
          // Uploaded already, only its index write pending: never again.
          if (!registry.isUploaded(asset.id) && !await registry.isPendingIndex(asset.id)) {
            final file = await _originFile(asset);
            if (file != null) {
              // The registry not knowing about this asset doesn't mean it
              // isn't already in the vault — a reinstall wipes the registry
              // (SharedPreferences) but not the cloud index, which is
              // reloaded fresh from Telegram on every login. Cross-check
              // there first so re-scanning a backup-enabled album after a
              // reinstall heals the registry instead of re-uploading and
              // duplicating every file in it.
              final existing = _ref.read(indexProvider).index.findUpload(
                    p.basename(file.path),
                    await file.length(),
                  );
              if (existing != null) {
                await registry.commitUploads([
                  (assetId: asset.id, fileItemId: existing.id, path: file.path),
                ]);
              } else {
                final item = await _uploadAsset(asset, file, _onProgress);
                // Persisted before anything else: from here on the file is
                // on Telegram, and a failed index write must not make the
                // asset look not-uploaded (that re-uploaded it, every pass).
                try {
                  await registry.addPendingIndex(
                    assetId: asset.id,
                    fileItemId: item.id,
                    itemJson: pendingItemJson(item),
                    path: file.path,
                  );
                } catch (e) {
                  unsaved.add(item.id);
                  debugPrint('TVQUEUE: pending-index row not written (${e.runtimeType})');
                }
                pending.add((item: item, assetId: asset.id, path: file.path));
              }
            }
          }
          state = state.copyWith(done: state.done + 1, currentProgress: 0);
          _consecutiveAuthKeyDead = 0;
        } catch (e) {
          debugPrint('TVQUEUE: upload failed asset=${asset.id}: ${logSafeError(e)}');
          state = state.copyWith(done: state.done + 1, failed: state.failed + 1, currentProgress: 0);
          if (_noteFailure(e)) {
            state = state.copyWith(canceling: true);
            _uploads.clear();
            _downloads.clear();
          }
        }
        debugPrint('TVQUEUE: ${state.done}/${state.total} (up) asset=${asset.id}');
        // Failed or skipped items are settled now; uploaded ones stay active
        // until flush() has written them to the index and registry.
        if (!pending.any((p) => p.assetId == asset.id)) _active.remove(asset.id);
        if (pending.length >= _flushEvery) await flush();
        // Yield to the event loop so the UI stays responsive between items.
        await Future.delayed(Duration.zero);
      }
      await flush();

      // --- Downloads ---
      while (_downloads.isNotEmpty && !state.canceling) {
        unawaited(registry.markQueueHeartbeat());
        final item = _downloads.removeAt(0);
        _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
        state = state.copyWith(
          kind: TransferKind.download,
          currentName: item.name,
          currentProgress: 0,
        );
        try {
          if (!await LocalFileService.instance.isSaved(item)) {
            await LocalFileService.instance.save(item, onProgress: _onProgress);
          }
          state = state.copyWith(done: state.done + 1, currentProgress: 0);
          _consecutiveAuthKeyDead = 0;
        } catch (e) {
          debugPrint('TVQUEUE: download failed file=${item.id}: ${logSafeError(e)}');
          state = state.copyWith(done: state.done + 1, failed: state.failed + 1, currentProgress: 0);
          if (_noteFailure(e)) {
            state = state.copyWith(canceling: true);
            _uploads.clear();
            _downloads.clear();
          }
        }
        debugPrint('TVQUEUE: ${state.done}/${state.total} (down) file=${item.id}');
        await Future.delayed(Duration.zero);
      }
      _maybeBump(force: true);

      debugPrint('TVQUEUE: DONE ${state.done}/${state.total} (failed ${state.failed})');
    } finally {
      _running = false;
      if (heldForIndex && _uploads.isNotEmpty && !state.canceling) {
        // Not restarted here (that would spin on a failing load): the index
        // listener, or the next enqueue, resumes the queue.
        _waitingForIndex = true;
        state = state.copyWith(
          kind: TransferKind.upload,
          currentName: indexNotLoadedNotice,
          currentProgress: 0,
        );
        unawaited(BackgroundExecutionService.instance.disable());
      } else if ((_uploads.isNotEmpty || _downloads.isNotEmpty || _retryWhenIdle) &&
          !state.canceling) {
        // If new work (or a pending-index retry) arrived while finishing,
        // keep going; else reset to idle.
        _ensureRunning();
      } else {
        state = const TransferState();
        unawaited(BackgroundExecutionService.instance.disable());
      }
    }
  }
}

final transferQueueProvider =
    StateNotifierProvider<TransferQueueNotifier, TransferState>(
        (ref) => TransferQueueNotifier(ref));
