import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/upload/upload_service.dart';
import '../../explorer/providers/index_provider.dart';

class UploadState {
  final bool isUploading;
  final double progress;
  final String? fileName;
  final String? error;

  const UploadState({
    this.isUploading = false,
    this.progress = 0,
    this.fileName,
    this.error,
  });

  UploadState copyWith({
    bool? isUploading,
    double? progress,
    String? fileName,
    String? error,
  }) =>
      UploadState(
        isUploading: isUploading ?? this.isUploading,
        progress: progress ?? this.progress,
        fileName: fileName ?? this.fileName,
        error: error,
      );
}

class UploadNotifier extends StateNotifier<UploadState> {
  UploadNotifier(this._ref) : super(const UploadState());
  final Ref _ref;

  /// Opens the system file picker, uploads the chosen file to Telegram, then
  /// records it in the index. No-op if the user cancels.
  Future<void> pickAndUpload({String? folderId}) async {
    final picked = await FilePicker.platform.pickFiles();
    final path = picked?.files.single.path;
    if (path == null) return;

    final file = File(path);
    state = UploadState(
      isUploading: true,
      progress: 0,
      fileName: picked!.files.single.name,
    );

    try {
      final item = await UploadService.instance.uploadFile(
        file,
        folderId: folderId,
        onProgress: (p) => state = state.copyWith(progress: p),
      );
      // Persist the new file into the Telegram-backed index.
      await _ref.read(indexProvider.notifier).addFile(item);
      state = state.copyWith(isUploading: false, progress: 1);
    } catch (e) {
      state = state.copyWith(isUploading: false, error: e.toString());
    }
  }
}

final uploadProvider =
    StateNotifierProvider<UploadNotifier, UploadState>((ref) => UploadNotifier(ref));
