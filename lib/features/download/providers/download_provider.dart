import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../core/download/download_service.dart';
import '../../../models/file_item.dart';

class DownloadState {
  /// Id of the file currently downloading, or null when idle.
  final String? fileId;
  final double progress;
  final String? error;

  const DownloadState({this.fileId, this.progress = 0, this.error});

  bool get isDownloading => fileId != null;

  DownloadState copyWith({String? fileId, double? progress, String? error}) =>
      DownloadState(
        fileId: fileId,
        progress: progress ?? this.progress,
        error: error,
      );
}

class DownloadNotifier extends StateNotifier<DownloadState> {
  DownloadNotifier() : super(const DownloadState());

  /// Downloads [item] into the app's TeleVault folder and opens it with the
  /// system's default handler.
  Future<void> downloadAndOpen(FileItem item) async {
    state = DownloadState(fileId: item.id, progress: 0);
    try {
      final docs = await getApplicationDocumentsDirectory();
      final destDir = Directory(p.join(docs.path, 'TeleVault'));
      await destDir.create(recursive: true);

      final file = await DownloadService.instance.downloadFile(
        item,
        destDir: destDir.path,
        onProgress: (pr) => state = state.copyWith(fileId: item.id, progress: pr),
      );

      await OpenFilex.open(file.path);
      state = const DownloadState();
    } catch (e) {
      state = DownloadState(error: e.toString());
    }
  }
}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, DownloadState>((_) => DownloadNotifier());
