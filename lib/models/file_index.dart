import 'dart:convert';
import 'album.dart';
import 'file_item.dart';
import 'folder.dart';

/// The whole organizational state of the vault: folders, files, and albums.
/// This is the single source of truth, stored in Telegram.
class FileIndex {
  static const int currentVersion = 1;

  final int version;
  final List<Folder> folders;
  final List<FileItem> files;
  final List<Album> albums;

  const FileIndex({
    this.version = currentVersion,
    this.folders = const [],
    this.files = const [],
    this.albums = const [],
  });

  /// An empty index, used the first time the app runs on an account.
  factory FileIndex.empty() => const FileIndex();

  /// Merges independently-evolved index snapshots into one — recovery for
  /// when [IndexService.load] lost track of the real index mid-session and
  /// started fresh empty ones on top of it instead of finding it (see
  /// [IndexService.findAllIndexSnapshots]). Folders/files are unioned by id;
  /// each id was only ever added once across the fragmented lineages (never
  /// edited independently in two of them), so last-write-wins is equivalent
  /// to a true union. Albums additionally union their member file ids, in
  /// case the same album gained different files in different lineages.
  factory FileIndex.merge(Iterable<FileIndex> snapshots) {
    final folders = <String, Folder>{};
    final files = <String, FileItem>{};
    final albums = <String, Album>{};
    for (final snap in snapshots) {
      for (final f in snap.folders) {
        folders[f.id] = f;
      }
      for (final f in snap.files) {
        files[f.id] = f;
      }
      for (final a in snap.albums) {
        final existing = albums[a.id];
        albums[a.id] = existing == null
            ? a
            : existing.copyWith(fileIds: {...existing.fileIds, ...a.fileIds}.toList());
      }
    }
    return FileIndex(
      folders: folders.values.toList(),
      files: files.values.toList(),
      albums: albums.values.toList(),
    );
  }

  factory FileIndex.fromJson(Map<String, dynamic> json) => FileIndex(
        version: json['version'] as int? ?? currentVersion,
        folders: (json['folders'] as List<dynamic>? ?? [])
            .map((e) => Folder.fromJson(e as Map<String, dynamic>))
            .toList(),
        files: (json['files'] as List<dynamic>? ?? [])
            .map((e) => FileItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        albums: (json['albums'] as List<dynamic>? ?? [])
            .map((e) => Album.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'folders': folders.map((f) => f.toJson()).toList(),
        'files': files.map((f) => f.toJson()).toList(),
        'albums': albums.map((a) => a.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  factory FileIndex.decode(String raw) =>
      FileIndex.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Files directly inside [folderId] (null = root).
  List<FileItem> filesIn(String? folderId) =>
      files.where((f) => f.folderId == folderId).toList();

  /// All images and videos across every folder, newest first — the gallery
  /// feed.
  List<FileItem> get mediaFiles {
    final media = files
        .where((f) => f.mimeType.startsWith('image/') || f.mimeType.startsWith('video/'))
        .toList();
    media.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return media;
  }

  /// Looks up files by id, preserving the given order; missing ids are skipped.
  List<FileItem> filesByIds(List<String> ids) {
    final byId = {for (final f in files) f.id: f};
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  }

  /// Folders directly inside [parentId] (null = root).
  List<Folder> foldersIn(String? parentId) =>
      folders.where((f) => f.parentId == parentId).toList();

  FileIndex copyWith({
    List<Folder>? folders,
    List<FileItem>? files,
    List<Album>? albums,
  }) =>
      FileIndex(
        version: version,
        folders: folders ?? this.folders,
        files: files ?? this.files,
        albums: albums ?? this.albums,
      );

  FileIndex addFile(FileItem file) => copyWith(files: [...files, file]);

  /// Adds several files at once — used by bulk uploads so the index is saved
  /// to Telegram a single time per batch instead of once per file.
  FileIndex addFiles(List<FileItem> newFiles) =>
      copyWith(files: [...files, ...newFiles]);

  /// Removes a file from the vault and from every album that referenced it.
  FileIndex removeFile(String fileId) => copyWith(
        files: files.where((f) => f.id != fileId).toList(),
        albums: albums
            .map((a) => a.fileIds.contains(fileId)
                ? a.copyWith(fileIds: a.fileIds.where((id) => id != fileId).toList())
                : a)
            .toList(),
      );

  FileIndex renameFile(String fileId, String name) => copyWith(
        files: files.map((f) => f.id == fileId ? f.copyWith(name: name) : f).toList(),
      );

  /// Moves [fileIds] into [targetFolderId] (null = root).
  FileIndex moveFiles(List<String> fileIds, String? targetFolderId) => copyWith(
        files: files
            .map((f) => fileIds.contains(f.id) ? f.copyWith(folderId: targetFolderId) : f)
            .toList(),
      );

  FileIndex addFolder(Folder folder) => copyWith(folders: [...folders, folder]);

  FileIndex renameFolder(String folderId, String name) => copyWith(
        folders: folders.map((f) => f.id == folderId ? f.copyWith(name: name) : f).toList(),
      );

  /// Moves [folderIds] into [targetParentId] (null = root).
  FileIndex moveFolders(List<String> folderIds, String? targetParentId) => copyWith(
        folders: folders
            .map((f) => folderIds.contains(f.id) ? f.copyWith(parentId: targetParentId) : f)
            .toList(),
      );

  /// All descendant folder ids of [folderId] (for excluding invalid move
  /// targets — you can't move a folder into itself or its own subtree).
  Set<String> descendantFolderIds(String folderId) {
    final result = <String>{};
    void recurse(String id) {
      for (final f in folders.where((f) => f.parentId == id)) {
        if (result.add(f.id)) recurse(f.id);
      }
    }
    recurse(folderId);
    return result;
  }

  /// Removes a folder and detaches its direct children to the root so nothing
  /// is silently orphaned.
  FileIndex removeFolder(String folderId) => copyWith(
        folders: folders.where((f) => f.id != folderId).toList(),
        files: files
            .map((f) => f.folderId == folderId ? f.copyWith(folderId: null) : f)
            .toList(),
      );

  // --- Albums ---

  FileIndex addAlbum(Album album) => copyWith(albums: [...albums, album]);

  FileIndex removeAlbum(String albumId) =>
      copyWith(albums: albums.where((a) => a.id != albumId).toList());

  FileIndex renameAlbum(String albumId, String name) => copyWith(
        albums: albums
            .map((a) => a.id == albumId ? a.copyWith(name: name) : a)
            .toList(),
      );

  /// Adds [fileIds] to [albumId], skipping ids already present.
  FileIndex addToAlbum(String albumId, List<String> fileIds) => copyWith(
        albums: albums.map((a) {
          if (a.id != albumId) return a;
          final merged = [...a.fileIds];
          for (final id in fileIds) {
            if (!merged.contains(id)) merged.add(id);
          }
          return a.copyWith(fileIds: merged);
        }).toList(),
      );

  FileIndex removeFromAlbum(String albumId, List<String> fileIds) => copyWith(
        albums: albums.map((a) {
          if (a.id != albumId) return a;
          return a.copyWith(
            fileIds: a.fileIds.where((id) => !fileIds.contains(id)).toList(),
          );
        }).toList(),
      );
}
