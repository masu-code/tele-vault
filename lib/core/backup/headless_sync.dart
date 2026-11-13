import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:tv_core/codecs.dart' show PreviewCodec;
import 'package:workmanager/workmanager.dart';
import '../device/device_library.dart';
import '../../models/file_item.dart';
import '../index/index_service.dart';
import '../metadata/capture_date_recovery.dart';
import '../telegram/client.dart';
import '../thumbnail/auto_maintenance_service.dart';
import '../thumbnail/auto_pack_service.dart';
import '../thumbnail/backfill_service.dart';
import '../upload/upload_service.dart';
import 'backup_registry.dart';
import 'connectivity_gate.dart';
import 'transfer_notifications.dart';

/// Unique name (and task name) of the periodic CHECK: a plain background
/// worker, no notification. It only looks for pending files and, when there
/// are some, schedules [uploadRunTaskName].
const uploadSyncTaskName = 'televault-upload-sync';

/// Unique name (and task name) of the one-off UPLOAD RUN, scheduled by the
/// check with [headlessForegroundConfig]: a foreground service with the
/// progress notification, shown only when there is real work.
const uploadRunTaskName = 'televault-upload-run';

/// Unique name (and task name) of the periodic MAINTENANCE task: thumbnail
/// packs, capture dates and the thumbnail backfill of old items, which
/// downloads originals. WorkManager only starts it on an unmetered network
/// while the device is charging.
const maintenanceTaskName = 'televault-maintenance';

/// Backfill chunks of [AutoMaintenanceService.backfillChunk] items one
/// maintenance task may run (each chunk is saved before the next starts).
const maintenanceBackfillChunks = 20;

/// How long one foreground run may keep starting new uploads.
///
/// The run is a foreground service ([headlessForegroundConfig]), so it is not
/// cut at WorkManager's usual 10 minutes; a large backlog is worked through
/// for this long per run (the file in flight when it runs out still
/// finishes), and the next check schedules another run for the rest.
const headlessRunBudget = Duration(minutes: 45);

/// Budget of the inline fallback (the one-off could not be scheduled): a
/// plain worker is stopped by WorkManager at 10 minutes.
const inlineRunBudget = Duration(minutes: 8);

/// Which job [callbackDispatcher] runs for a WorkManager task name.
enum HeadlessJob { check, uploadRun, maintenance, unknown }

HeadlessJob headlessJobFor(String task) => switch (task) {
      uploadSyncTaskName => HeadlessJob.check,
      uploadRunTaskName => HeadlessJob.uploadRun,
      maintenanceTaskName => HeadlessJob.maintenance,
      _ => HeadlessJob.unknown,
    };

/// What the periodic check did.
enum HeadlessCheckOutcome { nothingToDo, scheduled, ranInline }

/// The check's decision: with nothing pending, nothing happens (no
/// notification); otherwise the foreground run is scheduled, and only if
/// that fails does the upload run inline in the check itself.
Future<HeadlessCheckOutcome> scheduleOrRunInline({
  required int pendingCount,
  required Future<void> Function() scheduleForegroundRun,
  required Future<void> Function() runInline,
}) async {
  if (pendingCount <= 0) return HeadlessCheckOutcome.nothingToDo;
  try {
    await scheduleForegroundRun();
    return HeadlessCheckOutcome.scheduled;
  } catch (e) {
    debugPrint('TVBG: foreground run not scheduled (${logSafeError(e)}), running inline');
  }
  await runInline();
  return HeadlessCheckOutcome.ranInline;
}

/// Enqueues the foreground upload run. `keep`: a run already queued or in
/// progress is left alone, so checks during a long run add nothing.
Future<void> _scheduleForegroundRun() => Workmanager().registerOneOffTask(
      uploadRunTaskName,
      uploadRunTaskName,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      foregroundServiceConfig: headlessForegroundConfig(),
    );

/// Registers the periodic CHECK (Android only; WorkManager is already
/// initialized by `main`). `update` (not `keep`) so the registered spec always
/// matches this code; it keeps the existing schedule and never cancels a
/// running run. Called at start-up when a session exists and after a login.
Future<void> scheduleHeadlessSync() async {
  if (!Platform.isAndroid) return;
  await Workmanager().registerPeriodicTask(
    uploadSyncTaskName,
    uploadSyncTaskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
  await Workmanager().registerPeriodicTask(
    maintenanceTaskName,
    maintenanceTaskName,
    frequency: const Duration(minutes: 30),
    constraints: Constraints(networkType: NetworkType.unmetered, requiresCharging: true),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
}

/// Log out: cancels the periodic check and any queued or running foreground
/// run (both unique names). Best effort per task; nothing on other platforms.
Future<void> cancelHeadlessSync() async {
  if (!Platform.isAndroid) return;
  for (final name in const [uploadSyncTaskName, uploadRunTaskName, maintenanceTaskName]) {
    try {
      await Workmanager().cancelByUniqueName(name);
    } catch (e) {
      debugPrint('TVBG: could not cancel a background task (${e.runtimeType})');
    }
  }
}

/// Uploads are written to the index in batches of this many files, or after
/// [headlessFlushAfter] with anything pending, so a run that is stopped early
/// (the OS, a lost foreground service, the app opening) leaves at most one
/// small batch uploaded but not yet in the index.
///
/// 2 min, not more: if the promotion to a foreground service fails (Android
/// 12+ refuses it from the background without an exemption), WorkManager
/// stops the run at about 10 min, and whatever was uploaded but not flushed
/// becomes orphan messages that the next run uploads again. The stop signal
/// ([callbackDispatcher]'s onTaskStopped) also flushes, best effort.
const headlessFlushEvery = 8;
const headlessFlushAfter = Duration(minutes: 2);

/// Whether a headless run should write its [pendingUploads] to the index
/// now, [sinceFlush] after the last write.
bool headlessFlushDue(int pendingUploads, Duration sinceFlush) =>
    pendingUploads >= headlessFlushEvery ||
    (pendingUploads > 0 && sinceFlush >= headlessFlushAfter);

/// Uploads ([U]) and dedupe hits ([H]) of a headless run waiting for their
/// index/registry write. [flush] calls are serialized (the run's own batch
/// flush and the one on the stop signal never overlap), and each writes a
/// snapshot and then removes exactly that snapshot, so an upload finishing
/// while a flush is in flight stays queued for the next one.
class HeadlessBatch<U, H> {
  HeadlessBatch(this._write);

  final Future<void> Function(List<U> uploads, List<H> hits) _write;
  final uploads = <U>[];
  final hits = <H>[];
  final _sinceFlush = Stopwatch()..start();
  Future<void> _chain = Future.value();

  bool get isDue => headlessFlushDue(uploads.length, _sinceFlush.elapsed);

  Future<void> flush() {
    final run = _chain.then((_) => _flushNow());
    _chain = run.catchError((_) {});
    return run;
  }

  Future<void> _flushNow() async {
    if (uploads.isEmpty && hits.isEmpty) return;
    final u = List.of(uploads);
    final h = List.of(hits);
    await _write(u, h);
    // Only appends happen meanwhile, so the snapshot is the prefix.
    uploads.removeRange(0, u.length);
    hits.removeRange(0, h.length);
    _sinceFlush.reset();
  }
}

/// The upload run in progress in this engine, for the stop signal.
_ActiveRun? _activeRun;

class _ActiveRun {
  _ActiveRun(this.flush);
  final Future<void> Function() flush;
  bool stopRequested = false;
}

/// How long the stop handler waits for its flush: the engine is torn down
/// once it returns, and the process may be killed anyway.
const _stopFlushTimeout = Duration(seconds: 30);

/// WorkManager stopped the running task (timeout, quota, constraints...):
/// write what was uploaded but not yet flushed, and stop starting uploads.
Future<void> _onTaskStopped(String task, StopReason reason) async {
  _activeMaintenance?.stop();
  final run = _activeRun;
  if (run == null) return;
  run.stopRequested = true;
  // An enum value (WorkManager's stop reason), never user data.
  final why = reason.name;
  try {
    await run.flush().timeout(_stopFlushTimeout);
    await BackupRegistry.instance
        .recordHeadlessRun('stopped by the system ($why), batch saved');
    debugPrint('TVBG: stopped by the system ($why), batch saved');
  } catch (e) {
    debugPrint('TVBG: stop flush failed: ${logSafeError(e)}');
  }
}

/// Promotes the one-off upload run ([uploadRunTaskName]) to an Android
/// foreground service (type dataSync) for the whole run. Same notification id and channel as the
/// transfer progress notification, so the progress shown by the run replaces
/// the service notification instead of adding a second one.
ForegroundServiceConfig headlessForegroundConfig() => ForegroundServiceConfig(
      notificationTitle: 'TeleVault backup',
      notificationText: 'Checking for new photos and videos',
      notificationChannelId: TransferNotifications.channelId,
      notificationChannelName: TransferNotifications.channelName,
      notificationId: TransferNotifications.progressId,
      foregroundServiceType: ForegroundServiceType.dataSync,
    );

/// Records a headless outcome (logged and shown in the account sheet).
typedef _Done = Future<void> Function(String status);

Future<_Done> _openRegistry(BackupRegistry registry) async {
  await registry.init();
  return (String status) async {
    debugPrint('TVBG: $status');
    await registry.recordHeadlessRun(status);
  };
}

/// The periodic CHECK ([uploadSyncTaskName]): cheap, no notification. With
/// files pending (and the app not alive), schedules the foreground upload
/// run; if that cannot be scheduled, uploads inline within [inlineRunBudget].
Future<void> runHeadlessCheck() async {
  final registry = BackupRegistry.instance;
  final done = await _openRegistry(registry);
  final pending = await _pendingIfDue(registry, done);
  if (pending == null) return;
  final count = pending.assets.length + pending.unindexed;
  final outcome = await scheduleOrRunInline(
    pendingCount: count,
    scheduleForegroundRun: _scheduleForegroundRun,
    runInline: () => _runUploads(registry, done, pending.assets, inlineRunBudget),
  );
  if (outcome == HeadlessCheckOutcome.scheduled) {
    await done('$count pending — foreground run scheduled');
  }
}

/// The foreground UPLOAD RUN ([uploadRunTaskName]): re-checks (the app may
/// have opened since the check) and uploads for up to [headlessRunBudget].
///
/// Runs with no UI or Riverpod context, so pending photos in backup-enabled
/// albums keep getting uploaded even if TeleVault was never opened (or was
/// fully closed) since they landed on the device. Mirrors
/// BackupNotifier.syncAll()'s logic (same registry, same connectivity rule).
///
/// Every exit records what happened via [BackupRegistry.recordHeadlessRun], so
/// the account sheet can show whether (and why not) the task last did work.
Future<void> runHeadlessSync() async {
  final registry = BackupRegistry.instance;
  final done = await _openRegistry(registry);
  final pending = await _pendingIfDue(registry, done);
  if (pending == null) return;
  await _runUploads(registry, done, pending.assets, headlessRunBudget);
  // Right after its uploads: pack the new thumbnails and recover dates (no
  // backfill here: charging is not known in this task). Its failure must not
  // replace the upload status recorded above.
  try {
    await runHeadlessMaintenance(charging: false, afterUploads: true);
  } catch (e) {
    debugPrint('TVBG: maintenance failed (${e.runtimeType})');
  }
}

/// The maintenance job running in this engine, for the stop signal.
AutoMaintenanceService? _activeMaintenance;

/// Automatic maintenance in a headless engine: thumbnail packs and capture
/// dates on an unmetered network, plus backfill chunks when [charging] (the
/// [maintenanceTaskName] task, whose constraints guarantee it). Skipped while
/// the app is alive (it runs its own) and when another job holds the lock.
/// Logs counts only.
Future<void> runHeadlessMaintenance({required bool charging, bool afterUploads = false}) async {
  final registry = BackupRegistry.instance;
  await registry.init();
  await registry.reload();
  if (registry.appRecentlyAlive) {
    debugPrint('TVBG: maintenance skipped — app is running');
    return;
  }
  if (!afterUploads && !await TelegramService.instance.restoreSession()) {
    debugPrint('TVBG: maintenance skipped — no session to restore');
    return;
  }
  final index = IndexServiceAccess(IndexService.instance);
  if (!await index.load()) {
    debugPrint('TVBG: maintenance skipped — index not loaded');
    return;
  }
  final service = AutoMaintenanceService(
    packer: AutoPackService(index: index),
    dates: CaptureDateRecoveryService(index: index),
    backfill: BackfillService(index: index),
    lock: MaintenanceLock.standard(),
    unmetered: unmeteredNetwork,
    charging: () async => charging,
    userBusy: () => registry.queueRecentlyActive || registry.appRecentlyAlive,
    maxBackfillChunks: charging ? maintenanceBackfillChunks : 0,
    budget: inlineRunBudget,
  );
  _activeMaintenance = service;
  try {
    final r = await service.runOnce(queueJustFinished: afterUploads);
    debugPrint('TVBG: maintenance ${r.skipped ?? 'done'} packs=${r.packs} '
        'dates=${r.datesProcessed} backfillChunks=${r.backfillChunks} '
        'produced=${r.backfillProduced}');
  } finally {
    if (identical(_activeMaintenance, service)) _activeMaintenance = null;
  }
}

/// The pending assets of the backup-enabled albums (minus those uploaded and
/// only waiting for their index write) and how many such uploads wait, or
/// null (status already recorded) when a headless run must not or need not
/// run now. A run with no assets but uploads to index still runs: indexing
/// them is its first step.
Future<({List<AssetEntity> assets, int unindexed})?> _pendingIfDue(
  BackupRegistry registry,
  _Done done,
) async {
  // Pull the registry rows the app wrote since this engine loaded them.
  await registry.reload();

  // Liveness comes from the heartbeat files (see heartbeat.dart), which
  // every engine of the process reads directly.
  //
  // The live in-app queue (and its real-time device-change watcher) already
  // covers this while the app is open — skip this run if it was active
  // moments ago, rather than opening a second independent connection.
  if (registry.queueRecentlyActive) {
    await done('skipped — app queue recently active');
    return null;
  }
  // ...and not only while its queue is mid-upload: a live app process can
  // start uploading at any moment (watcher, auto-sync), so it owns uploads
  // for as long as it's alive. Running alongside it put two CPU-heavy upload
  // connections on one account at once.
  if (registry.appRecentlyAlive) {
    await done('skipped — app is running (it owns uploads)');
    return null;
  }

  final enabledIds = registry.enabledAlbumIds.toSet();
  if (enabledIds.isEmpty) {
    await done('skipped — no albums enabled for backup');
    return null;
  }

  if (!await hasUsableConnection()) {
    await done('skipped — no usable connection (Wi-Fi only?)');
    return null;
  }

  // Deliberately not calling PhotoManager.getPermissionState() here: on
  // Android, that call needs an Activity bound to the plugin
  // (PermissionsUtils.context is only ever set from onAttachedToActivity)
  // and throws a NullPointerException in a headless WorkManager engine,
  // which has none. The data calls below (getAssetPathList, the album pages
  // DeviceLibrary reads, originFile) only need the application context. If
  // permission was revoked since the app was last open, these just return
  // empty/throw a normal catchable error instead of crashing.
  final albums = await PhotoManager.getAssetPathList(
    type: RequestType.image | RequestType.video,
  );
  // Only enabled albums that still exist on the device.
  final albumIds = {
    for (final a in albums)
      if (enabledIds.contains(a.id)) a.id,
  };
  final unindexed = (await registry.pendingIndexAssetIds()).toSet();
  final pending = albumIds.isEmpty
      ? const <AssetEntity>[]
      : await DeviceLibrary.instance.pendingFor(
          albumIds,
          (id) => registry.isUploaded(id) || unindexed.contains(id),
        );
  if (pending.isEmpty && unindexed.isEmpty) {
    await done(
      'nothing pending (${albums.length} albums, ${enabledIds.length} enabled)',
    );
    return null;
  }
  return (assets: pending, unindexed: unindexed.length);
}

/// Uploads [file] (the original of [asset]) and returns its [FileItem];
/// [onProgress] gets 0..1.
typedef HeadlessUpload = Future<FileItem> Function(
  AssetEntity asset,
  File file,
  void Function(double progress) onProgress,
);

/// What one [runHeadlessUploadPass] did.
typedef HeadlessPassResult = ({
  int uploaded,
  int inVault,
  int linked,
  int attempted,
  bool stoppedForApp,
  bool stoppedForTime,
  bool stopRequested,
});

Future<FileItem> _defaultHeadlessUpload(
  AssetEntity asset,
  File file,
  void Function(double progress) onProgress,
) async {
  // Null (upload without a preview) on any failure — see uploadThumbFor.
  final thumb = await uploadThumbFor(asset);
  // No UI here: the pure-Dart decode of the small thumb is fine.
  final hash = thumb == null ? null : PreviewCodec.encodeJpeg(thumb);
  final item = await UploadService.instance.uploadFile(
    file,
    thumbJpeg: thumb,
    preview: hash == null ? null : PreviewCodec.toWire(hash),
    takenAtMs: assetTakenAtMs(asset),
    onProgress: onProgress,
  );
  await rememberUploadedThumb(item.id, thumbJpeg: thumb, previewHash: hash);
  return item;
}

/// Uploads [pending] for up to [budget], writing the index in batches.
Future<void> _runUploads(
  BackupRegistry registry,
  _Done done,
  List<AssetEntity> pending,
  Duration budget,
) async {
  final restored = await TelegramService.instance.restoreSession();
  if (!restored) {
    await done('skipped — no session to restore');
    return;
  }

  debugPrint('TVBG: ${pending.length} pending file(s)');

  // The progress bar in the system notification is what tells the user the
  // app is really working while it's closed. Always cleared on the way out —
  // an exception below must not leave an ongoing notification stuck on screen.
  final notifications = TransferNotifications.instance;
  final HeadlessPassResult r;
  try {
    r = await runHeadlessUploadPass(
      registry: registry,
      indexService: IndexService.instance,
      pending: pending,
      budget: budget,
      beginAsset: (n, asset) async {
        // Bar = this file's progress, batch position in the title — same as
        // the in-app queue's notification (see main_shell.dart
        // _syncNotification).
        final title = 'Backing up $n of ${pending.length}';
        final body = asset.title ?? 'Photo';
        await notifications.showProgress(
          title: title,
          body: '$body · 0%',
          done: 0,
          total: 1,
          force: true,
        );
        // Moves the bar within the file, not only between files — a long
        // video otherwise sat frozen at the same spot for minutes.
        // showProgress throttles itself to one update per 1.5s.
        return (progress) => unawaited(notifications.showProgress(
              title: title,
              body: '$body · ${(progress * 100).round()}%',
              done: 0,
              total: 1,
              current: progress,
            ));
      },
    );
  } finally {
    await notifications.cancel();
  }

  final stopped = r.stoppedForApp
      ? ' — stopped early, app opened'
      : r.stopRequested
          ? ' — stopped by the system, rest next run'
          : r.stoppedForTime
              ? ' — time budget used, rest next run'
              : '';
  if (r.linked == 0) {
    await done(r.stoppedForApp
        ? 'stopped — app opened before anything was uploaded'
        : 'nothing saved: ${r.attempted} of ${pending.length} attempted$stopped');
    return;
  }
  await done(
    'uploaded ${r.uploaded} of ${pending.length} pending, ${r.attempted} attempted '
    '(${r.inVault} already in vault)$stopped',
  );
  if (r.uploaded > 0) {
    await notifications.showDone('Backed up ${r.uploaded} new file(s)');
  }
}

/// The upload loop of a headless run, with its Telegram, device and
/// notification parts injectable (tests).
///
/// First writes the uploads a failed index write left behind (registry
/// pending-index rows) to the index, then uploads [pending]. Every upload is
/// recorded as a pending-index row right after it reaches Telegram, so a
/// failed or interrupted index write never makes the next run upload it
/// again; assets with such a row are skipped. A failed index write throws
/// (as before); the rows stay for the next run.
@visibleForTesting
Future<HeadlessPassResult> runHeadlessUploadPass({
  required BackupRegistry registry,
  required IndexService indexService,
  required List<AssetEntity> pending,
  required Duration budget,
  Future<File?> Function(AssetEntity asset)? originFile,
  HeadlessUpload? upload,
  Future<void Function(double progress)> Function(int n, AssetEntity asset)? beginAsset,
}) async {
  final origin = originFile ?? (AssetEntity a) => a.originFile;
  final send = upload ?? _defaultHeadlessUpload;

  // Dedupe source; replaced by the index each flush writes.
  var index = await indexService.load();

  var uploaded = 0;
  var inVault = 0;
  var linked = 0;

  // [toIndex] plus every pending-index row; dedupe hits are linked as given.
  Future<void> write(List<FinishedUpload> toIndex, List<UploadLink> hits) async {
    final uploads = [...toIndex];
    for (final row in await registry.pendingIndex()) {
      final u = finishedUploadFromRow(row);
      if (u != null) uploads.add(u);
    }
    final r = await indexPendingUploads(
      uploads: uploads,
      alreadyInVault: hits,
      save: (addMissing) async {
        // Reload right before writing: the uploads above can take minutes.
        // The save rebases onto anything written meanwhile, and the index it
        // returns is the one kept from here on.
        final fresh = await indexService.load();
        final next = addMissing(fresh);
        if (identical(next, fresh)) return (index: fresh, dropped: const <String>[]);
        var dropped = const <String>[];
        final written = await indexService.save(
          next,
          onDroppedDuplicates: (ids) => dropped = List.of(ids),
        );
        return (index: written, dropped: dropped);
      },
      commitUploads: registry.commitUploads,
      unlinkFileItem: registry.unlinkFileItem,
      removePending: registry.removePendingIndex,
    );
    if (uploads.isNotEmpty) index = r.written;
    linked += r.links.length;
  }

  // Uploaded files waiting for their index write, and dedupe hits waiting
  // for their registry link.
  final batch = HeadlessBatch<FinishedUpload, UploadLink>(write);
  final toIndex = batch.uploads;
  final hits = batch.hits;
  Future<void> flush() => batch.flush();
  final run = _ActiveRun(flush);
  _activeRun = run;

  final elapsed = Stopwatch()..start();
  var n = 0;
  var stoppedForApp = false;
  var stoppedForTime = false;
  try {
    // What an earlier failed index write left: indexed before any upload.
    await write(const [], const []);

    for (final asset in pending) {
      // WorkManager stopped the task: its handler flushes; start nothing new.
      if (run.stopRequested) break;
      if (elapsed.elapsed >= budget) {
        stoppedForTime = true;
        break;
      }
      // A run can take many minutes. If the app is opened meanwhile, hand
      // uploads over to it at the next file boundary instead of running a
      // second upload connection alongside its own; what finished so far is
      // still saved below.
      if (registry.appRecentlyAlive) {
        stoppedForApp = true;
        break;
      }
      try {
        // Linked meanwhile (the pending-index rows indexed above), or
        // uploaded already with only its index write pending: never
        // uploaded again.
        if (registry.isUploaded(asset.id) || await registry.isPendingIndex(asset.id)) {
          continue;
        }
        n++;
        final onProgress = await beginAsset?.call(n, asset) ?? (double _) {};
        final file = await origin(asset);
        if (file == null) continue;
        // The registry not knowing about this asset doesn't mean it isn't
        // already in the vault — a reinstall wipes the registry but not the
        // cloud index. Cross-check there first so a backup-enabled album
        // re-scanned after a reinstall heals the registry instead of
        // re-uploading and duplicating every file in it.
        final existing = index.findUpload(
          p.basename(file.path),
          await file.length(),
        );
        if (existing != null) {
          hits.add((assetId: asset.id, fileItemId: existing.id, path: file.path));
          inVault++;
        } else {
          final item = await send(asset, file, onProgress);
          // Persisted before the flush: from here on the file is on Telegram.
          try {
            await registry.addPendingIndex(
              assetId: asset.id,
              fileItemId: item.id,
              itemJson: pendingItemJson(item),
              path: file.path,
            );
          } catch (e) {
            debugPrint('TVBG: pending-index row not written (${e.runtimeType})');
          }
          toIndex.add((item: item, assetId: asset.id, path: file.path));
          uploaded++;
        }
      } catch (e) {
        // Best effort — left unmarked, retried on the next periodic run.
        debugPrint('TVBG: asset ${asset.id} failed: ${logSafeError(e)}');
      }
      if (batch.isDue) await flush();
    }
    await flush();
  } finally {
    if (identical(_activeRun, run)) _activeRun = null;
  }
  return (
    uploaded: uploaded,
    inVault: inVault,
    linked: linked,
    attempted: n,
    stoppedForApp: stoppedForApp,
    stoppedForTime: stoppedForTime,
    stopRequested: run.stopRequested,
  );
}

/// Entry point WorkManager invokes (in its own headless Flutter engine, with
/// full plugin support) whenever the periodic check or the one-off upload run
/// is due; [task] is the task name each was registered with. Must be a
/// top-level function annotated exactly like this — the native side calls it
/// via a fixed callback handle, not through normal Dart imports.
@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    final job = headlessJobFor(task);
    if (job != HeadlessJob.unknown) {
      try {
        if (job == HeadlessJob.check) {
          await runHeadlessCheck();
        } else if (job == HeadlessJob.maintenance) {
          await runHeadlessMaintenance(charging: true);
        } else {
          await runHeadlessSync();
        }
      } catch (e) {
        // Swallow — WorkManager reruns this on its own schedule regardless;
        // returning false would only trigger its own extra retry on top of
        // that, for a run that's likely to fail the same way again anyway.
        // But record it: this used to vanish without a trace.
        try {
          final registry = BackupRegistry.instance;
          await registry.init();
          await registry.recordHeadlessRun('error: ${logSafeError(e)}');
        } catch (_) {}
      }
    }
    return true;
  }, onTaskStopped: _onTaskStopped);
}
