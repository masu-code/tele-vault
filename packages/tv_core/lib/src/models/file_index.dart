import 'dart:convert';
import 'album.dart';
import 'file_item.dart';
import 'folder.dart';
import 'json_equality.dart';
import 'thumb_pack_ref.dart';

/// Outcome of [FileIndex.rebase].
class RebaseResult {
  /// The rebased index, ready to be written.
  final FileIndex index;

  /// Ids of local additions dropped because the remote already holds a file
  /// with the same name and size under another id (ids only, never names).
  /// Callers should unlink these from their upload registry.
  final List<String> droppedDuplicates;

  const RebaseResult({required this.index, required this.droppedDuplicates});
}

/// The whole organizational state of the vault: folders, files, and albums.
/// This is the single source of truth, stored in Telegram.
class FileIndex {
  static const int currentVersion = 1;

  final int version;
  final List<Folder> folders;
  final List<FileItem> files;
  final List<Album> albums;

  /// Thumbnail packs (TVTP v1) stored in the channel. Omitted from the JSON
  /// when empty.
  final List<ThumbPackRef> thumbPacks;

  /// JSON keys this version does not know about, preserved verbatim and
  /// written after the known keys (known keys win on read).
  final Map<String, dynamic> extra;

  const FileIndex({
    this.version = currentVersion,
    this.folders = const [],
    this.files = const [],
    this.albums = const [],
    this.thumbPacks = const [],
    this.extra = const {},
  });

  static const Set<String> _knownKeys = {
    'version',
    'folders',
    'files',
    'albums',
    'thumb_packs',
  };

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
    final packs = <int, ThumbPackRef>{};
    final extra = <String, dynamic>{};
    for (final snap in snapshots) {
      for (final f in snap.folders) {
        folders[f.id] = f;
      }
      for (final f in snap.files) {
        // Keep an earlier preview when the later snapshot has none.
        final earlier = files[f.id];
        files[f.id] = (f.preview == null && earlier?.preview != null)
            ? f.copyWith(preview: earlier!.preview)
            : f;
      }
      for (final p in snap.thumbPacks) {
        packs[p.messageId] = p;
      }
      extra.addAll(snap.extra);
      for (final a in snap.albums) {
        final existing = albums[a.id];
        // Later snapshots win for the album's own fields (name etc.); only the
        // member ids are unioned.
        albums[a.id] = existing == null
            ? a
            : a.copyWith(fileIds: {...existing.fileIds, ...a.fileIds}.toList());
      }
    }
    return FileIndex(
      folders: folders.values.toList(),
      files: files.values.toList(),
      albums: albums.values.toList(),
      thumbPacks: packs.values.toList(),
      extra: extra.isEmpty ? const {} : extra,
    );
  }

  factory FileIndex.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? extra;
    for (final e in json.entries) {
      if (!_knownKeys.contains(e.key)) (extra ??= {})[e.key] = e.value;
    }
    return FileIndex(
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
      thumbPacks: (json['thumb_packs'] as List<dynamic>? ?? [])
          .map((e) => ThumbPackRef.fromJson(e as Map<String, dynamic>))
          .toList(),
      extra: extra ?? const {},
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'version': version,
      'folders': folders.map((f) => f.toJson()).toList(),
      'files': files.map((f) => f.toJson()).toList(),
      'albums': albums.map((a) => a.toJson()).toList(),
    };
    if (thumbPacks.isNotEmpty) {
      m['thumb_packs'] = thumbPacks.map((p) => p.toJson()).toList();
    }
    for (final e in extra.entries) {
      m.putIfAbsent(e.key, () => e.value);
    }
    return m;
  }

  String encode() => jsonEncode(toJson());

  factory FileIndex.decode(String raw) =>
      FileIndex.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Files directly inside [folderId] (null = root).
  List<FileItem> filesIn(String? folderId) =>
      files.where((f) => f.folderId == folderId).toList();

  /// All non-archived images and videos across every folder, newest first —
  /// the Gallery feed. Archived media is deliberately excluded here (not just
  /// filtered by callers) so every current and future caller of this getter
  /// hides it by construction; see [archivedMediaFiles] for the Archive
  /// screen's own listing.
  List<FileItem> get mediaFiles {
    final media = files
        .where((f) =>
            !f.archived &&
            (f.mimeType.startsWith('image/') || f.mimeType.startsWith('video/')))
        .toList();
    media.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return media;
  }

  /// The mirror of [mediaFiles]: only archived images/videos, newest first.
  List<FileItem> get archivedMediaFiles {
    final media = files
        .where((f) =>
            f.archived &&
            (f.mimeType.startsWith('image/') || f.mimeType.startsWith('video/')))
        .toList();
    media.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return media;
  }

  /// Looks up files by id, preserving the given order; missing ids are skipped.
  List<FileItem> filesByIds(List<String> ids) {
    final byId = {for (final f in files) f.id: f};
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  }

  /// Finds a file already in the vault matching a device asset's original
  /// filename and exact byte size — used to recognize a device asset as
  /// already backed up even when the local upload registry has no record of
  /// it (e.g. wiped by a reinstall), so a re-scanned backup-enabled album
  /// doesn't re-upload and duplicate content that's already in Telegram. This
  /// index is fetched fresh from Telegram on every login and isn't affected
  /// by local app data being cleared, unlike the registry.
  FileItem? findUpload(String name, int totalSize) {
    for (final f in files) {
      if (f.name == name && f.totalSize == totalSize) return f;
    }
    return null;
  }

  /// Folders directly inside [parentId] (null = root).
  List<Folder> foldersIn(String? parentId) =>
      folders.where((f) => f.parentId == parentId).toList();

  FileIndex copyWith({
    List<Folder>? folders,
    List<FileItem>? files,
    List<Album>? albums,
    List<ThumbPackRef>? thumbPacks,
  }) =>
      FileIndex(
        version: version,
        folders: folders ?? this.folders,
        files: files ?? this.files,
        albums: albums ?? this.albums,
        thumbPacks: thumbPacks ?? this.thumbPacks,
        extra: extra,
      );

  /// Sets [FileItem.preview] from [previews] (file id -> `th1:` string). An
  /// existing preview is kept unless [overwrite]. Returns `this` when nothing
  /// changes.
  FileIndex withPreviews(Map<String, String> previews, {bool overwrite = false}) {
    if (previews.isEmpty) return this;
    var changed = false;
    final updated = <FileItem>[];
    for (final f in files) {
      final p = previews[f.id];
      if (p != null && p != f.preview && (overwrite || f.preview == null)) {
        updated.add(f.copyWith(preview: p));
        changed = true;
      } else {
        updated.add(f);
      }
    }
    return changed ? copyWith(files: updated) : this;
  }

  /// Registers a thumbnail pack, replacing any existing entry with the same
  /// [ThumbPackRef.messageId].
  FileIndex addThumbPack(ThumbPackRef pack) {
    final i = thumbPacks.indexWhere((p) => p.messageId == pack.messageId);
    if (i < 0) return copyWith(thumbPacks: [...thumbPacks, pack]);
    final next = [...thumbPacks];
    next[i] = pack;
    return copyWith(thumbPacks: next);
  }

  /// Three-way merge used when a writer finds the remote index changed under
  /// it. [base] is the index as this writer last saw it remote, [local] is
  /// its edited copy, [remote] is what is stored now. Per collection (files,
  /// folders, albums), keyed by id:
  ///
  /// * start from [remote] (its order is kept);
  /// * local deletions (in base, not in local) are applied;
  /// * local additions (not in base, in local) are appended unless remote
  ///   already has the id; an addition whose (name, totalSize) already exists
  ///   in remote under another id is dropped and reported in
  ///   [RebaseResult.droppedDuplicates];
  /// * ids present in all three: take local when local differs from base,
  ///   otherwise keep remote;
  /// * album `fileIds` are merged as sets (remote order first, then local
  ///   additions, minus local removals);
  /// * previews: a non-null preview wins, local over remote;
  /// * thumb packs: union by messageId (local over remote);
  /// * ids of locally deleted files are removed from albums, and locally
  ///   deleted folders detach remote-side children to the root.
  static RebaseResult rebase({
    required FileIndex base,
    required FileIndex local,
    required FileIndex remote,
  }) {
    final dropped = <String>[];

    // --- Files ---
    final localFileIds = {for (final f in local.files) f.id};
    final deletedFileIds = {
      for (final f in base.files)
        if (!localFileIds.contains(f.id)) f.id,
    };
    // Files deleted locally are not duplicates of anything: a local delete +
    // re-upload of the same file under a new id must keep the new one.
    final remoteByNameSize = <String, String>{};
    for (final f in remote.files) {
      if (deletedFileIds.contains(f.id)) continue;
      remoteByNameSize.putIfAbsent('${f.name}\u0000${f.totalSize}', () => f.id);
    }
    final idRemap = <String, String>{};
    final files = _rebaseById<FileItem>(
      base: base.files,
      local: local.files,
      remote: remote.files,
      idOf: (f) => f.id,
      resolve: (b, l, r) {
        // `preview` is merged separately below, so a local change that only
        // adds a preview must not override a remote edit of the file.
        final chosen = (b != null &&
                !jsonDeepEquals(_withoutKey(b.toJson(), 'preview'),
                    _withoutKey(l.toJson(), 'preview')))
            ? l
            : r;
        final p = l.preview ?? r.preview;
        return chosen.preview == p ? chosen : chosen.copyWith(preview: p);
      },
      accept: (l) {
        final dup = remoteByNameSize['${l.name}\u0000${l.totalSize}'];
        if (dup != null) {
          dropped.add(l.id);
          idRemap[l.id] = dup;
          return null;
        }
        return l;
      },
    );
    // --- Folders ---
    var folders = _rebaseById<Folder>(
      base: base.folders,
      local: local.folders,
      remote: remote.folders,
      idOf: (f) => f.id,
      resolve: (b, l, r) =>
          (b != null && !jsonDeepEquals(b.toJson(), l.toJson())) ? l : r,
      accept: (l) => l,
    );
    final localFolderIds = {for (final f in local.folders) f.id};
    final deletedFolderIds = {
      for (final f in base.folders)
        if (!localFolderIds.contains(f.id)) f.id,
    };
    var fixedFiles = files;
    if (deletedFolderIds.isNotEmpty) {
      folders = [
        for (final f in folders)
          deletedFolderIds.contains(f.parentId) ? f.copyWith(parentId: null) : f,
      ];
      fixedFiles = [
        for (final f in files)
          deletedFolderIds.contains(f.folderId) ? f.copyWith(folderId: null) : f,
      ];
    }

    // --- Albums ---
    List<String> mergeIds(Album? b, Album l, Album r) {
      final baseIds = (b?.fileIds ?? const <String>[]).toSet();
      final removed = baseIds.difference(l.fileIds.toSet());
      final merged = <String>[];
      final seen = <String>{};
      for (final id in r.fileIds) {
        if (!removed.contains(id) && seen.add(id)) merged.add(id);
      }
      for (final id in l.fileIds) {
        if (baseIds.contains(id)) continue;
        final mapped = idRemap[id] ?? id;
        if (seen.add(mapped)) merged.add(mapped);
      }
      return merged;
    }

    var albums = _rebaseById<Album>(
      base: base.albums,
      local: local.albums,
      remote: remote.albums,
      idOf: (a) => a.id,
      resolve: (b, l, r) {
        // `file_ids` is merged as a set by mergeIds, so a local change that
        // only adds members must not override a remote rename.
        final chosen = (b != null &&
                !jsonDeepEquals(_withoutKey(b.toJson(), 'file_ids'),
                    _withoutKey(l.toJson(), 'file_ids')))
            ? l
            : r;
        return chosen.copyWith(fileIds: mergeIds(b, l, r));
      },
      accept: (l) =>
          l.copyWith(fileIds: [for (final id in l.fileIds) idRemap[id] ?? id]),
    );
    if (deletedFileIds.isNotEmpty) {
      albums = [
        for (final a in albums)
          a.fileIds.any(deletedFileIds.contains)
              ? a.copyWith(
                  fileIds:
                      a.fileIds.where((id) => !deletedFileIds.contains(id)).toList(),
                )
              : a,
      ];
    }

    // --- Thumb packs: union by messageId, local over remote ---
    final packs = <int, ThumbPackRef>{
      for (final p in remote.thumbPacks) p.messageId: p,
    };
    for (final p in local.thumbPacks) {
      packs[p.messageId] = p;
    }

    // --- Unknown top-level keys: remote, plus local changes vs base ---
    final extra = <String, dynamic>{...remote.extra};
    for (final e in local.extra.entries) {
      if (!base.extra.containsKey(e.key) ||
          !jsonDeepEquals(base.extra[e.key], e.value)) {
        extra[e.key] = e.value;
      }
    }

    return RebaseResult(
      index: FileIndex(
        version: remote.version,
        folders: folders,
        files: fixedFiles,
        albums: albums,
        thumbPacks: packs.values.toList(),
        extra: extra.isEmpty ? const {} : extra,
      ),
      droppedDuplicates: dropped,
    );
  }

  static Map<String, dynamic> _withoutKey(Map<String, dynamic> json, String key) =>
      json.containsKey(key) ? (Map<String, dynamic>.of(json)..remove(key)) : json;

  /// Core of [rebase] for one collection. [resolve] receives the base item
  /// (null when both sides added the id), the local item and the remote item.
  /// [accept] receives a purely local addition and returns the item to append,
  /// or null to drop it.
  static List<T> _rebaseById<T>({
    required List<T> base,
    required List<T> local,
    required List<T> remote,
    required String Function(T) idOf,
    required T Function(T? base, T local, T remote) resolve,
    required T? Function(T local) accept,
  }) {
    final baseById = {for (final x in base) idOf(x): x};
    final localById = {for (final x in local) idOf(x): x};
    final remoteIds = {for (final x in remote) idOf(x)};
    final out = <T>[];
    for (final r in remote) {
      final id = idOf(r);
      final l = localById[id];
      final b = baseById[id];
      if (l == null) {
        // In base but not local = deleted locally; otherwise a remote-only add.
        if (b == null) out.add(r);
      } else {
        out.add(resolve(b, l, r));
      }
    }
    for (final l in local) {
      final id = idOf(l);
      if (baseById.containsKey(id) || remoteIds.contains(id)) continue;
      final accepted = accept(l);
      if (accepted != null) out.add(accepted);
    }
    return out;
  }

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

  /// Marks [fileIds] archived — hidden from Gallery/Albums (see [mediaFiles])
  /// without touching Telegram or album membership; unarchiving restores it
  /// exactly where it was.
  FileIndex archiveFiles(List<String> fileIds) => copyWith(
        files: files
            .map((f) => fileIds.contains(f.id) ? f.copyWith(archived: true) : f)
            .toList(),
      );

  FileIndex unarchiveFiles(List<String> fileIds) => copyWith(
        files: files
            .map((f) => fileIds.contains(f.id) ? f.copyWith(archived: false) : f)
            .toList(),
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
