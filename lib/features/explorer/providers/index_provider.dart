import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/index/index_service.dart';
import '../../../models/album.dart';
import '../../../models/file_index.dart';
import '../../../models/file_item.dart';
import '../../../models/folder.dart';

const _uuid = Uuid();

class IndexState {
  final FileIndex index;
  final bool isLoading;
  final bool isSaving;
  final String? error;

  const IndexState({
    this.index = const FileIndex(),
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  IndexState copyWith({
    FileIndex? index,
    bool? isLoading,
    bool? isSaving,
    String? error,
  }) =>
      IndexState(
        index: index ?? this.index,
        isLoading: isLoading ?? this.isLoading,
        isSaving: isSaving ?? this.isSaving,
        error: error,
      );
}

class IndexNotifier extends StateNotifier<IndexState> {
  IndexNotifier() : super(const IndexState());

  /// Loads the index from Telegram. Call once the user is authenticated.
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final index = await IndexService.instance.load();
      state = state.copyWith(index: index, isLoading: false);
      // One-time upgrade from a legacy text-message index to a document.
      if (IndexService.instance.needsMigration) {
        state = state.copyWith(isSaving: true);
        await IndexService.instance.save(index);
        state = state.copyWith(isSaving: false);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, isSaving: false, error: e.toString());
    }
  }

  /// Applies [mutation] to the current index, persists it to Telegram, and
  /// rolls back the in-memory state if the write fails.
  Future<void> _mutate(FileIndex Function(FileIndex) mutation) async {
    final previous = state.index;
    final next = mutation(previous);
    state = state.copyWith(index: next, isSaving: true, error: null);
    try {
      await IndexService.instance.save(next);
      state = state.copyWith(isSaving: false);
    } catch (e) {
      // Roll back so the UI never shows state that isn't in Telegram.
      state = state.copyWith(index: previous, isSaving: false, error: e.toString());
    }
  }

  Future<void> createFolder(String name, {String? parentId}) =>
      _mutate((i) => i.addFolder(
            Folder(id: _uuid.v4(), name: name, parentId: parentId),
          ));

  Future<void> removeFolder(String folderId) =>
      _mutate((i) => i.removeFolder(folderId));

  Future<void> renameFolder(String folderId, String name) =>
      _mutate((i) => i.renameFolder(folderId, name));

  Future<void> renameFile(String fileId, String name) =>
      _mutate((i) => i.renameFile(fileId, name));

  Future<void> moveItems(
    List<String> fileIds,
    List<String> folderIds,
    String? targetFolderId,
  ) =>
      _mutate((i) =>
          i.moveFiles(fileIds, targetFolderId).moveFolders(folderIds, targetFolderId));

  /// Deletes selected files (from Telegram + index) and folders together.
  Future<void> deleteItems(List<FileItem> files, List<String> folderIds) async {
    if (files.isEmpty && folderIds.isEmpty) return;
    state = state.copyWith(isSaving: true, error: null);
    try {
      if (files.isNotEmpty) {
        await IndexService.instance.deleteFromTelegram(files);
      }
      var next = state.index;
      for (final f in files) {
        next = next.removeFile(f.id);
      }
      for (final id in folderIds) {
        next = next.removeFolder(id);
      }
      await IndexService.instance.save(next);
      state = state.copyWith(index: next, isSaving: false);
    } catch (e) {
      state = state.copyWith(isSaving: false, error: e.toString());
    }
  }

  Future<void> addFile(FileItem file) => _mutate((i) => i.addFile(file));

  Future<void> removeFile(String fileId) => _mutate((i) => i.removeFile(fileId));

  /// Permanently deletes [items] from Telegram and the index. Not optimistic:
  /// the index is only updated after Telegram confirms the deletion.
  Future<void> deleteFiles(List<FileItem> items) async {
    if (items.isEmpty) return;
    state = state.copyWith(isSaving: true, error: null);
    try {
      await IndexService.instance.deleteFromTelegram(items);
      var next = state.index;
      for (final item in items) {
        next = next.removeFile(item.id);
      }
      await IndexService.instance.save(next);
      state = state.copyWith(index: next, isSaving: false);
    } catch (e) {
      state = state.copyWith(isSaving: false, error: e.toString());
    }
  }

  // --- Albums ---

  Future<void> createAlbum(String name, {List<String> fileIds = const []}) =>
      _mutate((i) => i.addAlbum(Album(
            id: _uuid.v4(),
            name: name,
            fileIds: fileIds,
            createdAt: DateTime.now().toUtc(),
          )));

  Future<void> renameAlbum(String albumId, String name) =>
      _mutate((i) => i.renameAlbum(albumId, name));

  Future<void> removeAlbum(String albumId) =>
      _mutate((i) => i.removeAlbum(albumId));

  Future<void> addToAlbum(String albumId, List<String> fileIds) =>
      _mutate((i) => i.addToAlbum(albumId, fileIds));

  Future<void> removeFromAlbum(String albumId, List<String> fileIds) =>
      _mutate((i) => i.removeFromAlbum(albumId, fileIds));
}

final indexProvider =
    StateNotifierProvider<IndexNotifier, IndexState>((_) => IndexNotifier());
