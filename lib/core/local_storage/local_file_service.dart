import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../models/file_item.dart';
import '../backup/backup_registry.dart';
import '../download/download_service.dart';

/// Saves vault files to the device's real storage (outside the app) and tracks
/// whether a file is already there. This is the explicit "download to device"
/// action, separate from the transparent cache used for viewing.
///
/// On Android, images/videos are inserted straight into the system Gallery
/// via photo_manager (MediaStore) — the same place the Camera/WhatsApp save
/// to — so they're actually visible to the user, not just written to an
/// app-private folder they'd never find. Everything else (desktop, or
/// non-media file types) falls back to the platform's Downloads directory.
class LocalFileService {
  LocalFileService._();
  static final LocalFileService instance = LocalFileService._();

  Future<Directory> _targetDir() async =>
      (await getDownloadsDirectory()) ?? (await getApplicationDocumentsDirectory());

  Future<File> savedFileFor(FileItem item) async =>
      File(p.join((await _targetDir()).path, item.name));

  /// Resolves [item] to a file that actually exists on disk right now: either
  /// the original file it was uploaded from (via the backup link — a
  /// photo_manager-tracked asset, must be deleted through PhotoManager), or
  /// the explicit Downloads-folder copy from [save] (a plain file this app
  /// wrote, safe to delete directly). Null if neither exists.
  ///
  /// Public (not just [isSaved]) because "delete from device" needs to know
  /// not just whether a local copy exists but *which* one, since the two
  /// require different deletion mechanisms.
  Future<LocalFileMatch?> existingLocalFile(FileItem item) async {
    final linked = BackupRegistry.instance.localPathFor(item.id);
    if (linked != null) {
      final f = File(linked);
      if (await f.exists()) return LocalFileMatch(f, isLinkedAsset: true);
    }
    final downloaded = await savedFileFor(item);
    if (await downloaded.exists() && await downloaded.length() == item.totalSize) {
      return LocalFileMatch(downloaded, isLinkedAsset: false);
    }
    return null;
  }

  /// Whether [item] is already saved on the device: either explicitly saved
  /// via [save] (same name/size in the Downloads dir), or it's the very file
  /// that was uploaded by device backup and still sits at its original path.
  Future<bool> isSaved(FileItem item) async => await existingLocalFile(item) != null;

  /// Saves [item] to device storage (bringing it through the cache first) and
  /// returns the saved file. Images/videos on Android land in the system
  /// Gallery (and get linked in the backup registry, so "on device" tracking
  /// and delete-source choices work exactly like a device-backed-up photo).
  Future<File> save(FileItem item, {void Function(double)? onProgress}) async {
    final cached = await DownloadService.instance.downloadToCache(item, onProgress: onProgress);

    if (Platform.isAndroid &&
        (item.mimeType.startsWith('image/') || item.mimeType.startsWith('video/'))) {
      final isVideo = item.mimeType.startsWith('video/');
      // Without an explicit relativePath, Android dumps these into the
      // generic Pictures/Movies folder mixed with everything else — give
      // them their own findable album instead.
      final asset = isVideo
          ? await PhotoManager.editor.saveVideo(
              cached, title: item.name, relativePath: 'Movies/TeleVault')
          : await PhotoManager.editor.saveImageWithPath(
              cached.path, title: item.name, relativePath: 'Pictures/TeleVault');
      final saved = await asset.file;
      if (saved != null) {
        final registry = BackupRegistry.instance;
        await registry.linkLocalPath(item.id, saved.path);
        await registry.linkFileItem(asset.id, item.id);
        // This asset is a fresh copy of a file already in Telegram — mark it
        // uploaded so auto-backup doesn't see a "new" device photo and
        // re-upload a duplicate of something we just downloaded.
        await registry.markUploaded(asset.id);
        return saved;
      }
    }

    final dest = await savedFileFor(item);
    return cached.copy(dest.path);
  }
}

/// A local file found for a [FileItem], and whether it's tracked by
/// photo_manager (the device's original photo/video, uploaded from there) or
/// a plain file this app wrote itself (the explicit Downloads-folder save).
class LocalFileMatch {
  const LocalFileMatch(this.file, {required this.isLinkedAsset});

  final File file;
  final bool isLinkedAsset;
}
