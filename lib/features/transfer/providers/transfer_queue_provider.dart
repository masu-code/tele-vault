import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/background_execution_service.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/local_storage/local_file_service.dart';
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
  final double currentProgress; // 0..1 of the file in flight
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
class TransferQueueNotifier extends StateNotifier<TransferState> {
  TransferQueueNotifier(this._ref) : super(const TransferState());

  final Ref _ref;

  /// How many uploads to accumulate before writing them to the index (and
  /// refreshing the feed) in one go.
  static const _flushEvery = 8;

  final List<AssetEntity> _uploads = [];
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
    final queued = _uploads.map((a) => a.id).toSet();
    final fresh = assets.where((a) => queued.add(a.id)).toList();
    if (fresh.isEmpty) return;
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
    _downloads.clear();
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
    final registry = BackupRegistry.instance;
    await registry.init();

    try {
      // Buffer of successfully-uploaded items waiting to be written to the
      // index in one batch.
      final pending = <({FileItem item, String assetId, String path})>[];

      Future<void> flush() async {
        if (pending.isEmpty) return;
        await _ref.read(indexProvider.notifier).addFiles([for (final p in pending) p.item]);
        if (_ref.read(indexProvider).mutationError != null) {
          // The batch didn't persist — count them as failed and drop the
          // registry links so they're retried later rather than marked
          // uploaded-but-invisible.
          state = state.copyWith(failed: state.failed + pending.length);
        } else {
          for (final p in pending) {
            await registry.markUploaded(p.assetId);
            await registry.linkLocalPath(p.item.id, p.path);
            await registry.linkFileItem(p.assetId, p.item.id);
          }
        }
        pending.clear();
        _maybeBump();
      }

      // --- Uploads ---
      while (_uploads.isNotEmpty && !state.canceling) {
        // Tells the headless periodic background task (see
        // headless_sync.dart) this process already has an upload connection
        // open, so it skips its own run instead of opening a second one.
        unawaited(registry.markQueueHeartbeat());
        final asset = _uploads.removeAt(0);
        state = state.copyWith(
          kind: TransferKind.upload,
          currentName: asset.title ?? 'Uploading…',
          currentProgress: 0,
        );
        try {
          if (!registry.isUploaded(asset.id)) {
            final file = await asset.originFile;
            if (file != null) {
              final item = await UploadWorker.instance.uploadFile(
                file.path,
                onProgress: (p) => state = state.copyWith(currentProgress: p),
              );
              pending.add((item: item, assetId: asset.id, path: file.path));
            }
          }
          state = state.copyWith(done: state.done + 1);
          _consecutiveAuthKeyDead = 0;
        } catch (e) {
          debugPrint('TVQUEUE: upload failed ${asset.title}: $e');
          state = state.copyWith(done: state.done + 1, failed: state.failed + 1);
          if (_noteFailure(e)) {
            state = state.copyWith(canceling: true);
            _uploads.clear();
            _downloads.clear();
          }
        }
        debugPrint('TVQUEUE: ${state.done}/${state.total} (up) ${asset.title}');
        if (pending.length >= _flushEvery) await flush();
        // Yield to the event loop so the UI stays responsive between items.
        await Future.delayed(Duration.zero);
      }
      await flush();

      // --- Downloads ---
      while (_downloads.isNotEmpty && !state.canceling) {
        unawaited(registry.markQueueHeartbeat());
        final item = _downloads.removeAt(0);
        state = state.copyWith(
          kind: TransferKind.download,
          currentName: item.name,
          currentProgress: 0,
        );
        try {
          if (!await LocalFileService.instance.isSaved(item)) {
            await LocalFileService.instance.save(
              item,
              onProgress: (p) => state = state.copyWith(currentProgress: p),
            );
          }
          state = state.copyWith(done: state.done + 1);
          _consecutiveAuthKeyDead = 0;
        } catch (e) {
          debugPrint('TVQUEUE: download failed ${item.name}: $e');
          state = state.copyWith(done: state.done + 1, failed: state.failed + 1);
          if (_noteFailure(e)) {
            state = state.copyWith(canceling: true);
            _uploads.clear();
            _downloads.clear();
          }
        }
        debugPrint('TVQUEUE: ${state.done}/${state.total} (down) ${item.name}');
        await Future.delayed(Duration.zero);
      }
      _maybeBump(force: true);

      debugPrint('TVQUEUE: DONE ${state.done}/${state.total} (failed ${state.failed})');
    } finally {
      _running = false;
      // If new work arrived while finishing, keep going; else reset to idle.
      if ((_uploads.isNotEmpty || _downloads.isNotEmpty) && !state.canceling) {
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
