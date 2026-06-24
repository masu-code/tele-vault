import 'dart:io';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../models/file_item.dart';
import '../download/download_service.dart';

/// Saves vault files to the device's real storage (outside the app) and tracks
/// whether a file is already there. This is the explicit "download to device"
/// action, separate from the transparent cache used for viewing.
///
/// Cross-platform: on desktop this is the user's Downloads folder; on Android
/// it is the app's external files dir (visible to file managers). Revealing the
/// location opens the OS file explorer on desktop and the file itself on mobile.
///
/// NOTE (Android): surfacing saved photos/videos in the phone's Gallery would
/// need MediaStore integration (e.g. the `gal` package); that is deferred to
/// the Android pass, when it can actually be tested on a device.
class LocalFileService {
  LocalFileService._();
  static final LocalFileService instance = LocalFileService._();

  Future<Directory> _targetDir() async =>
      (await getDownloadsDirectory()) ?? (await getApplicationDocumentsDirectory());

  Future<File> savedFileFor(FileItem item) async =>
      File(p.join((await _targetDir()).path, item.name));

  /// Whether [item] is already saved on the device (same name and size).
  Future<bool> isSaved(FileItem item) async {
    final f = await savedFileFor(item);
    return await f.exists() && await f.length() == item.totalSize;
  }

  /// Saves [item] to device storage (bringing it through the cache first) and
  /// returns the saved file.
  Future<File> save(FileItem item, {void Function(double)? onProgress}) async {
    final cached = await DownloadService.instance.downloadToCache(item, onProgress: onProgress);
    final dest = await savedFileFor(item);
    return cached.copy(dest.path);
  }

  /// Reveals the saved file in the OS: file explorer on desktop (selecting it),
  /// or opening the file with the default handler on mobile.
  Future<void> reveal(FileItem item) async {
    final f = await savedFileFor(item);
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', f.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', f.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [f.parent.path]);
    } else {
      await OpenFilex.open(f.path);
    }
  }
}
