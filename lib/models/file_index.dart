import 'dart:convert';
import 'file_item.dart';
import 'folder.dart';

/// The whole organizational state of the vault: folders + files and where
/// they live. This is the single source of truth, stored in Telegram.
class FileIndex {
  static const int currentVersion = 1;

  final int version;
  final List<Folder> folders;
  final List<FileItem> files;

  const FileIndex({
    this.version = currentVersion,
    this.folders = const [],
    this.files = const [],
  });

  /// An empty index, used the first time the app runs on an account.
  factory FileIndex.empty() => const FileIndex();

  factory FileIndex.fromJson(Map<String, dynamic> json) => FileIndex(
        version: json['version'] as int? ?? currentVersion,
        folders: (json['folders'] as List<dynamic>? ?? [])
            .map((e) => Folder.fromJson(e as Map<String, dynamic>))
            .toList(),
        files: (json['files'] as List<dynamic>? ?? [])
            .map((e) => FileItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'folders': folders.map((f) => f.toJson()).toList(),
        'files': files.map((f) => f.toJson()).toList(),
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

  FileIndex copyWith({List<Folder>? folders, List<FileItem>? files}) =>
      FileIndex(
        version: version,
        folders: folders ?? this.folders,
        files: files ?? this.files,
      );

  FileIndex addFile(FileItem file) =>
      copyWith(files: [...files, file]);

  FileIndex removeFile(String fileId) =>
      copyWith(files: files.where((f) => f.id != fileId).toList());

  FileIndex addFolder(Folder folder) =>
      copyWith(folders: [...folders, folder]);

  /// Removes a folder and detaches its direct children to the root so nothing
  /// is silently orphaned.
  FileIndex removeFolder(String folderId) => copyWith(
        folders: folders.where((f) => f.id != folderId).toList(),
        files: files
            .map((f) => f.folderId == folderId ? f.copyWith(folderId: null) : f)
            .toList(),
      );
}
