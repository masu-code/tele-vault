import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/download/download_service.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../models/file_item.dart';
import '../../backup/providers/backup_provider.dart';

class DownloadState {
  /// Id of the file currently being fetched/saved, or null when idle.
  final String? fileId;
  final double progress;
  final String? error;

  /// Set once after a successful save, for a confirmation message.
  final String? savedMessage;

  const DownloadState({this.fileId, this.progress = 0, this.error, this.savedMessage});

  bool get isDownloading => fileId != null;

  DownloadState withProgress(String id, double p) =>
      DownloadState(fileId: id, progress: p);
}

class DownloadNotifier extends StateNotifier<DownloadState> {
  DownloadNotifier(this._ref) : super(const DownloadState());

  final Ref _ref;

  /// Opens [item] with the system's default handler. Brought into the app cache
  /// transparently (reused on later opens) — the automatic "view" path.
  Future<void> openWithSystem(FileItem item) async {
    state = DownloadState(fileId: item.id);
    try {
      final file = await DownloadService.instance.downloadToCache(
        item,
        onProgress: (pr) => state = state.withProgress(item.id, pr),
      );
      await OpenFilex.open(file.path);
      state = const DownloadState();
    } catch (e) {
      state = DownloadState(error: e.toString());
    }
  }

  /// Saves a real copy of [item] to device storage (the explicit download).
  Future<void> saveToDevice(FileItem item) async {
    state = DownloadState(fileId: item.id);
    try {
      await LocalFileService.instance.save(
        item,
        onProgress: (pr) => state = state.withProgress(item.id, pr),
      );
      // The save may have just created the "TeleVault" device album — the
      // Albums tab won't show it until the device-album list is re-fetched.
      await _ref.read(backupProvider.notifier).refreshDeviceAlbums();
      bumpDeviceState(_ref);
      state = const DownloadState(savedMessage: 'Saved to device — see the TeleVault album');
    } catch (e) {
      state = DownloadState(error: e.toString());
    }
  }

  /// Saves several files to device storage, skipping any already saved.
  Future<void> saveManyToDevice(List<FileItem> items) async {
    if (items.isEmpty) return;
    var saved = 0;
    var skipped = 0;
    try {
      for (final item in items) {
        if (await LocalFileService.instance.isSaved(item)) {
          skipped++;
          continue;
        }
        state = DownloadState(fileId: item.id);
        await LocalFileService.instance.save(
          item,
          onProgress: (pr) => state = state.withProgress(item.id, pr),
        );
        saved++;
      }
      if (saved > 0) {
        await _ref.read(backupProvider.notifier).refreshDeviceAlbums();
        bumpDeviceState(_ref);
      }
      final msg = saved == 0
          ? 'Already on device'
          : 'Saved $saved to device (TeleVault album)${skipped > 0 ? ' ($skipped already saved)' : ''}';
      state = DownloadState(savedMessage: msg);
    } catch (e) {
      // Files saved before the failing one are already on disk — without
      // this, their "on device" indicators would stay stale until an
      // unrelated action elsewhere happens to bump the state.
      if (saved > 0) {
        await _ref.read(backupProvider.notifier).refreshDeviceAlbums();
        bumpDeviceState(_ref);
      }
      state = DownloadState(error: 'Saved $saved of ${items.length}; failed: $e');
    }
  }

}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, DownloadState>((ref) => DownloadNotifier(ref));
