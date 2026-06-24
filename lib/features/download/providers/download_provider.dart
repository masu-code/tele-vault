import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import '../../../core/download/download_service.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../../models/file_item.dart';

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
  DownloadNotifier() : super(const DownloadState());

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
      final saved = await LocalFileService.instance.save(
        item,
        onProgress: (pr) => state = state.withProgress(item.id, pr),
      );
      state = DownloadState(savedMessage: 'Saved to ${saved.path}');
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
      final msg = saved == 0
          ? 'Already on device'
          : 'Saved $saved to device${skipped > 0 ? ' ($skipped already saved)' : ''}';
      state = DownloadState(savedMessage: msg);
    } catch (e) {
      state = DownloadState(error: 'Saved $saved of ${items.length}; failed: $e');
    }
  }

  /// Opens the device file explorer at the saved file's location.
  Future<void> revealOnDevice(FileItem item) async {
    try {
      await LocalFileService.instance.reveal(item);
    } catch (e) {
      state = DownloadState(error: e.toString());
    }
  }
}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, DownloadState>((_) => DownloadNotifier());
