import 'package:flutter/widgets.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:workmanager/workmanager.dart';
import '../../models/file_item.dart';
import '../index/index_service.dart';
import '../telegram/client.dart';
import '../upload/upload_service.dart';
import 'backup_registry.dart';
import 'connectivity_gate.dart';

/// Unique name WorkManager registers the periodic backup task under, and
/// the task name [callbackDispatcher] checks for.
const uploadSyncTaskName = 'televault-upload-sync';

/// At most this many pending files get uploaded in one run.
///
/// WorkManager expects a background task to finish within a bounded time,
/// and Android won't run this task more often than every ~15 minutes
/// regardless — a large backlog finishes incrementally over several runs
/// instead of risking one long run getting killed mid-way.
const _maxPerRun = 30;

/// Runs one incremental backup pass with no UI or Riverpod context — this is
/// what [callbackDispatcher] invokes on WorkManager's schedule, so pending
/// photos in backup-enabled albums keep getting uploaded even if TeleVault
/// was never opened (or was fully closed) since they landed on the device.
///
/// Mirrors BackupNotifier.syncAll()'s logic (same registry, same
/// connectivity rule) but written against plain services instead of a Ref,
/// since this runs in its own headless engine with no provider tree.
Future<void> runHeadlessSync() async {
  final registry = BackupRegistry.instance;
  await registry.init();

  // The live in-app queue (and its real-time device-change watcher) already
  // covers this while the app is open — skip this run if it was active
  // moments ago, rather than opening a second independent connection.
  if (registry.queueRecentlyActive) {
    debugPrint('TVBG: skipped — app queue recently active');
    return;
  }

  final enabledIds = registry.enabledAlbumIds.toSet();
  if (enabledIds.isEmpty) {
    debugPrint('TVBG: skipped — no albums enabled for backup');
    return;
  }

  if (!await hasUsableConnection()) {
    debugPrint('TVBG: skipped — no usable connection');
    return;
  }

  final restored = await TelegramService.instance.restoreSession();
  if (!restored) {
    debugPrint('TVBG: skipped — no session to restore');
    return;
  }

  // Deliberately not calling PhotoManager.getPermissionState() here: on
  // Android, that call needs an Activity bound to the plugin
  // (PermissionsUtils.context is only ever set from onAttachedToActivity)
  // and throws a NullPointerException in a headless WorkManager engine,
  // which has none. The actual data calls below (getAssetPathList,
  // getAssetListRange, originFile) go through a different path that only
  // needs the application context, so they work fine here. If permission
  // was somehow revoked since the last time the app was open, these just
  // return empty/throw a normal catchable error instead of crashing.
  final albums = await PhotoManager.getAssetPathList(
    type: RequestType.image | RequestType.video,
    filterOption: FilterOptionGroup(
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
    ),
  );

  final seen = <String>{};
  final pending = <AssetEntity>[];
  for (final album in albums) {
    if (!enabledIds.contains(album.id)) continue;
    final count = await album.assetCountAsync;
    if (count == 0) continue;
    final assets = await album.getAssetListRange(start: 0, end: count);
    for (final asset in assets) {
      if (registry.isUploaded(asset.id)) continue;
      if (seen.add(asset.id)) pending.add(asset);
    }
    if (pending.length >= _maxPerRun) break;
  }
  if (pending.isEmpty) {
    debugPrint('TVBG: nothing pending');
    return;
  }

  final batch = pending.take(_maxPerRun).toList();
  debugPrint('TVBG: uploading ${batch.length} pending file(s)');
  final uploaded = <FileItem>[];
  final links = <({String assetId, String fileItemId, String path})>[];

  for (final asset in batch) {
    try {
      final file = await asset.originFile;
      if (file == null) continue;
      final item = await UploadService.instance.uploadFile(file);
      uploaded.add(item);
      links.add((assetId: asset.id, fileItemId: item.id, path: file.path));
    } catch (_) {
      // Best effort — left unmarked, retried on the next periodic run.
    }
  }
  if (uploaded.isEmpty) {
    debugPrint('TVBG: all ${batch.length} attempt(s) failed, nothing to save');
    return;
  }

  final index = await IndexService.instance.load();
  await IndexService.instance.save(index.addFiles(uploaded));
  for (final link in links) {
    await registry.markUploaded(link.assetId);
    await registry.linkLocalPath(link.fileItemId, link.path);
    await registry.linkFileItem(link.assetId, link.fileItemId);
  }
  debugPrint('TVBG: done — uploaded ${uploaded.length}/${batch.length}');
}

/// Entry point WorkManager invokes (in its own headless Flutter engine, with
/// full plugin support) whenever the periodic task is due. Must be a
/// top-level function annotated exactly like this — the native side calls it
/// via a fixed callback handle, not through normal Dart imports.
@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    if (task == uploadSyncTaskName) {
      try {
        await runHeadlessSync();
      } catch (_) {
        // Swallow — WorkManager reruns this on its own schedule regardless;
        // returning false would only trigger its own extra retry on top of
        // that, for a run that's likely to fail the same way again anyway.
      }
    }
    return true;
  });
}
