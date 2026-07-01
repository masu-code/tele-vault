import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../../../core/backup/backup_registry.dart';
import '../../../core/upload/upload_service.dart';
import '../../explorer/providers/index_provider.dart';

class UploadState {
  final bool isUploading;
  final double progress; // progress of the current file (0..1)
  final String? fileName; // current file
  final int currentIndex; // 1-based index of the current file
  final int totalCount; // total files in this batch
  final String? error;

  const UploadState({
    this.isUploading = false,
    this.progress = 0,
    this.fileName,
    this.currentIndex = 0,
    this.totalCount = 0,
    this.error,
  });

  UploadState copyWith({
    bool? isUploading,
    double? progress,
    String? fileName,
    int? currentIndex,
    int? totalCount,
    String? error,
  }) =>
      UploadState(
        isUploading: isUploading ?? this.isUploading,
        progress: progress ?? this.progress,
        fileName: fileName ?? this.fileName,
        currentIndex: currentIndex ?? this.currentIndex,
        totalCount: totalCount ?? this.totalCount,
        error: error,
      );
}

class UploadNotifier extends StateNotifier<UploadState> {
  UploadNotifier(this._ref) : super(const UploadState());
  final Ref _ref;

  /// Opens the system file picker (multi-select) and uploads everything chosen.
  Future<void> pickAndUpload({String? folderId}) async {
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = picked?.paths.whereType<String>().toList() ?? [];
    await uploadPaths(paths, folderId: folderId);
  }

  /// Uploads each path in turn, recording every file in the index. Used by both
  /// the picker and drag-and-drop. A failure stops the batch and reports which
  /// file failed; files already uploaded stay.
  Future<void> uploadPaths(List<String> paths, {String? folderId}) async {
    if (paths.isEmpty) return;
    for (var i = 0; i < paths.length; i++) {
      final name = p.basename(paths[i]);
      state = UploadState(
        isUploading: true,
        progress: 0,
        fileName: name,
        currentIndex: i + 1,
        totalCount: paths.length,
      );
      try {
        final item = await UploadService.instance.uploadFile(
          File(paths[i]),
          folderId: folderId,
          onProgress: (pr) => state = state.copyWith(progress: pr),
        );
        await _ref.read(indexProvider.notifier).addFile(item);
        await BackupRegistry.instance.linkLocalPath(item.id, paths[i]);
      } catch (e) {
        state = state.copyWith(isUploading: false, error: 'Failed on $name: $e');
        return;
      }
    }
    state = const UploadState();
  }
}

final uploadProvider =
    StateNotifierProvider<UploadNotifier, UploadState>((ref) => UploadNotifier(ref));
