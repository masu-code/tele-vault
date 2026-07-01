import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/file_item.dart';
import '../backup/backup_registry.dart';
import '../download/download_service.dart';

/// Saves vault files to the device's real storage (outside the app) and tracks
/// whether a file is already there. This is the explicit "download to device"
/// action, separate from the transparent cache used for viewing.
///
/// Cross-platform: on desktop this is the user's Downloads folder; on Android
/// it is the app's external files dir (visible to file managers).
class LocalFileService {
  LocalFileService._();
  static final LocalFileService instance = LocalFileService._();

  Future<Directory> _targetDir() async =>
      (await getDownloadsDirectory()) ?? (await getApplicationDocumentsDirectory());

  Future<File> savedFileFor(FileItem item) async =>
      File(p.join((await _targetDir()).path, item.name));

  /// Resolves [item] to a file that actually exists on disk right now: either
  /// the original file it was uploaded from (via the backup link), or the
  /// explicit Downloads-folder copy from [save]. Null if neither exists.
  Future<File?> _existingLocalFile(FileItem item) async {
    final linked = BackupRegistry.instance.localPathFor(item.id);
    if (linked != null) {
      final f = File(linked);
      if (await f.exists()) return f;
    }
    final downloaded = await savedFileFor(item);
    if (await downloaded.exists() && await downloaded.length() == item.totalSize) {
      return downloaded;
    }
    return null;
  }

  /// Whether [item] is already saved on the device: either explicitly saved
  /// via [save] (same name/size in the Downloads dir), or it's the very file
  /// that was uploaded by device backup and still sits at its original path.
  Future<bool> isSaved(FileItem item) async => await _existingLocalFile(item) != null;

  /// Saves [item] to device storage (bringing it through the cache first) and
  /// returns the saved file.
  Future<File> save(FileItem item, {void Function(double)? onProgress}) async {
    final cached = await DownloadService.instance.downloadToCache(item, onProgress: onProgress);
    final dest = await savedFileFor(item);
    return cached.copy(dest.path);
  }
}
