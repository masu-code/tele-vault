import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import '../device/device_library.dart';
import '../upload/upload_service.dart';
import '../../models/file_item.dart';
import 'backup_registry.dart';

class BackupProgress {
  final int total;
  final int done;
  final String? currentName;
  final String? error;

  const BackupProgress({
    this.total = 0,
    this.done = 0,
    this.currentName,
    this.error,
  });

  bool get isIdle => total == 0;
  bool get isDone => total > 0 && done >= total;
  double get fraction => total == 0 ? 0 : done / total;
}

/// Scans a device album and uploads photos/videos not yet in the registry.
/// Only active on Android — returns immediately on other platforms.
class BackupService {
  static final instance = BackupService._();
  BackupService._();

  bool _running = false;

  /// Syncs [album]: uploads all assets that are not yet in the registry.
  /// [onProgress] is called on each step. [addFile] persists each uploaded
  /// item into the shared index — callers pass the Riverpod index provider's
  /// method so the UI (Gallery, Files) updates live instead of only after the
  /// index is next reloaded from Telegram.
  Future<void> syncAlbum(
    AssetPathEntity album,
    void Function(BackupProgress) onProgress,
    Future<void> Function(FileItem) addFile,
  ) async {
    if (!Platform.isAndroid) return;
    if (_running) return;
    _running = true;
    try {
      await _sync(album, onProgress, addFile);
    } finally {
      _running = false;
    }
  }

  Future<void> _sync(
    AssetPathEntity album,
    void Function(BackupProgress) onProgress,
    Future<void> Function(FileItem) addFile,
  ) async {
    final registry = BackupRegistry.instance;
    final pending =
        await DeviceLibrary.instance.pendingFor({album.id}, registry.isUploaded);

    if (pending.isEmpty) {
      onProgress(const BackupProgress());
      return;
    }

    int done = 0;
    onProgress(BackupProgress(total: pending.length, done: 0));

    for (final asset in pending) {
      final File? file = await asset.originFile;
      if (file == null) {
        done++;
        onProgress(BackupProgress(total: pending.length, done: done));
        continue;
      }

      onProgress(BackupProgress(
        total: pending.length,
        done: done,
        currentName: asset.title,
      ));

      try {
        final fileItem = await UploadService.instance.uploadFile(
          file,
          takenAtMs: assetTakenAtMs(asset),
        );
        await addFile(fileItem);
        await registry.markUploaded(asset.id);
        await registry.linkLocalPath(fileItem.id, file.path);
        await registry.linkFileItem(asset.id, fileItem.id);
      } catch (e) {
        debugPrint('BackupService: failed to upload ${asset.title}: $e');
      }

      done++;
      onProgress(BackupProgress(total: pending.length, done: done));
    }
  }

  /// Fetches all device albums on Android. Returns empty list on other platforms.
  static Future<List<AssetPathEntity>> deviceAlbums() async {
    if (!Platform.isAndroid) return [];
    try {
      final permitted = await PhotoManager.requestPermissionExtend();
      if (!permitted.hasAccess) return [];
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image | RequestType.video,
        filterOption: FilterOptionGroup(
          orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
        ),
      );
      // Exclude the virtual "Recent"/"all" album — it's just every real
      // album combined, which duplicates what the Gallery tab already shows
      // as one chronological timeline; listing it here too was confusing
      // next to the actual per-folder albums (Camera, WhatsApp, etc.).
      return albums.where((a) => !a.isAll).toList();
    } catch (e) {
      debugPrint('BackupService.deviceAlbums: $e');
      return [];
    }
  }
}
