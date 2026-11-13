import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
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

  /// Set only by [IndexNotifier.load] — a real load failure, with nothing
  /// usable to show. UIs may replace their whole body with an error view.
  final String? error;

  /// Set by a mutation (rename/move/delete/album op) failing. The index
  /// itself is still valid (mutations roll back in-memory on failure), so
  /// UIs should surface this as a transient toast, not blank the screen.
  final String? mutationError;

  /// True while [index] may be behind Telegram: it came from the on-device
  /// cache (or an earlier load) and the latest load could not reach the
  /// remote. Cleared by the next successful load or save.
  final bool stale;

  const IndexState({
    this.index = const FileIndex(),
    this.isLoading = false,
    this.isSaving = false,
    this.error,
    this.mutationError,
    this.stale = false,
  });

  IndexState copyWith({
    FileIndex? index,
    bool? isLoading,
    bool? isSaving,
    String? error,
    String? mutationError,
    bool? stale,
  }) =>
      IndexState(
        index: index ?? this.index,
        isLoading: isLoading ?? this.isLoading,
        isSaving: isSaving ?? this.isSaving,
        error: error,
        mutationError: mutationError,
        stale: stale ?? this.stale,
      );
}

class IndexNotifier extends StateNotifier<IndexState> {
  IndexNotifier(this._ref, {IndexService? service})
      : _service = service ?? IndexService.instance,
        super(const IndexState()) {
    try {
      _lifecycle = AppLifecycleListener(onResume: () => unawaited(checkForRemoteChange()));
    } catch (_) {
      // No widgets binding (plain unit tests): no resume check.
    }
  }

  final Ref _ref;
  final IndexService _service;
  AppLifecycleListener? _lifecycle;

  /// Actions queued or running on [_writeChain].
  int _queued = 0;

  /// The on-device cache is published once, on the first [load].
  bool _cachePublished = false;

  /// [state.index] holds something usable (the cache, or a completed load):
  /// a failed load then marks it [IndexState.stale] instead of an error.
  bool _hasUsableIndex = false;

  List<String> _lastDroppedDuplicates = const [];

  /// Ids of files the last save dropped because the remote index already
  /// holds the same file (name and size) under another id. A caller that
  /// links registry entries to the files it just added should skip these.
  List<String> get lastDroppedDuplicates => _lastDroppedDuplicates;

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  void _onDropped(List<String> ids) {
    _lastDroppedDuplicates = ids;
    unawaited(_unlinkDropped(ids));
  }

  Future<void> _unlinkDropped(List<String> ids) async {
    try {
      final registry = BackupRegistry.instance;
      await registry.init();
      for (final id in ids) {
        await registry.unlinkFileItem(id);
      }
    } catch (_) {
      // Best effort: a stale link only costs a later re-check.
    }
  }

  /// Saves [next] and returns the index actually written (it can include
  /// another writer's changes, rebased) — always the one put in state.
  Future<FileIndex> _save(FileIndex next) {
    _lastDroppedDuplicates = const [];
    return _service.save(next, onDroppedDuplicates: _onDropped);
  }

  /// Chains every mutation so overlapping writers (e.g. auto-backup adding a
  /// file while the user deletes another) can't both read the same
  /// `state.index` and race to `IndexService.save()` — whichever finished
  /// last would silently overwrite the other's change. Each queued action
  /// re-reads `state.index` only once its turn arrives.
  Future<void> _writeChain = Future.value();

  Future<void> _enqueue(Future<void> Function() action) {
    _queued++;
    final result = _writeChain.then((_) => action()).whenComplete(() => _queued--);
    _writeChain = result.catchError((_) {});
    return result;
  }

  /// Log out: back to the state of a fresh install. Waits (bounded) for the
  /// queued writes to settle first, so a save finishing late cannot put the
  /// old account's index back in state, then forgets the loaded index, the
  /// published-cache flag and the in-flight load. The device cache is
  /// deleted by [IndexService.clearLocal]; a login's [load] starts clean.
  Future<void> resetForLogout() async {
    try {
      await _writeChain.timeout(const Duration(seconds: 5));
    } catch (_) {}
    _cachePublished = false;
    _hasUsableIndex = false;
    _lastDroppedDuplicates = const [];
    _loading = null;
    if (mounted) state = const IndexState();
  }

  /// Log out, local half: [resetForLogout] plus [IndexService.clearLocal].
  Future<void> clearForLogout() async {
    await resetForLogout();
    await _service.clearLocal();
  }

  /// Loads the index from Telegram. Call once the user is authenticated.
  ///
  /// The first call publishes the on-device cache right away (decoded off
  /// the UI isolate; `isLoading` stays true until the remote answers). When
  /// the remote cannot be reached and the state already holds a usable index
  /// (the cache, or an earlier load), it is kept and marked
  /// [IndexState.stale] instead of setting `error`.
  ///
  /// Goes through the write chain: loading can consolidate snapshots (a
  /// write), and must not interleave with an in-flight mutation's save.
  Future<void> load() {
    state = state.copyWith(isLoading: true, error: null);
    final run = _enqueueLoad();
    _loading = run;
    run.whenComplete(() {
      if (identical(_loading, run)) _loading = null;
    }).ignore();
    return run;
  }

  /// The [load] currently queued or running, if any.
  Future<void>? _loading;

  /// True once a load or save of this session reached Telegram (see
  /// [IndexService.synced]). Until then [IndexState.index] is the device cache
  /// or empty, and cannot tell which files are already in the vault.
  bool get remoteSynced => _service.synced;

  /// Nothing queued or running on the write chain and no load/save in
  /// flight: a background writer (the capture-date stamp) may go now.
  bool get isIdle => _queued == 0 && !state.isLoading && !state.isSaving;

  /// Makes sure the index has been read from Telegram in this session before
  /// a caller dedupes against it (the upload queue). Waits for a load already
  /// in flight; if none succeeded yet, runs one. Returns [remoteSynced].
  Future<bool> ensureRemoteLoaded() async {
    if (_service.synced) return true;
    final inFlight = _loading;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
      if (_service.synced) return true;
    }
    try {
      await load();
    } catch (_) {}
    return _service.synced;
  }

  Future<void> _enqueueLoad() {
    return _enqueue(() async {
      if (!_cachePublished) {
        _cachePublished = true;
        final cached = await _service.readCache();
        if (cached != null && !_hasUsableIndex) {
          _hasUsableIndex = true;
          state = state.copyWith(index: cached, isLoading: true);
        }
      }
      final FileIndex index;
      try {
        index = await _service.load();
      } catch (e) {
        state = _hasUsableIndex
            ? state.copyWith(isLoading: false, isSaving: false, stale: true)
            : state.copyWith(isLoading: false, isSaving: false, error: e.toString());
        return;
      }
      _hasUsableIndex = true;
      state = state.copyWith(index: index, isLoading: false, stale: false);
      // One-time upgrade from a legacy text-message index to a document.
      if (_service.needsMigration) {
        try {
          state = state.copyWith(isSaving: true);
          final written = await _save(index);
          state = state.copyWith(index: written, isSaving: false);
        } catch (e) {
          state = state.copyWith(isLoading: false, isSaving: false, error: e.toString());
        }
      }
    });
  }

  /// On app resume: when nothing is queued, a cheap lookup compares the
  /// remote index document with the one last read or written, and reloads
  /// when another writer (the headless backup, another device) changed it.
  ///
  /// If the last load failed (offline cold start: the cache is shown as
  /// [IndexState.stale], or nothing usable and [IndexState.error]), the index
  /// was never synced and [IndexService.remoteChanged] cannot tell, so the
  /// load itself is retried.
  @visibleForTesting
  Future<void> checkForRemoteChange() async {
    if (_queued > 0 || state.isLoading || state.isSaving) return;
    if (_cachePublished && (state.stale || state.error != null)) {
      await load();
      return;
    }
    final changed = await _service.remoteChanged();
    if (changed == true && mounted && _queued == 0) await load();
  }

  /// Applies [mutation] to the current index, persists it to Telegram, and
  /// rolls back the in-memory state if the write fails.
  Future<void> _mutate(FileIndex Function(FileIndex) mutation) =>
      _run(mutation, rethrowOnFailure: false);

  /// Like a private mutation, for writers outside the notifier (the thumbnail
  /// backfill): [mutate] runs when its turn on the write chain arrives, against
  /// the then-current index, so a user mutation queued meanwhile is neither
  /// lost nor overwritten. Saves, puts the written index in state and returns
  /// it. When [mutate] returns the same instance nothing is saved. On failure
  /// the state rolls back (and [IndexState.mutationError] is set, as for any
  /// mutation) and the error is rethrown to the caller.
  ///
  /// [onDropped] receives the ids this save dropped as duplicates (empty when
  /// nothing was saved), read inside the write chain so a mutation queued
  /// right after cannot reset them first (see [lastDroppedDuplicates]).
  Future<FileIndex> applyAndSave(
    FileIndex Function(FileIndex current) mutate, {
    void Function(List<String> dropped)? onDropped,
  }) =>
      _run(mutate, rethrowOnFailure: true, skipIfUnchanged: true, onDropped: onDropped);

  Future<FileIndex> _run(
    FileIndex Function(FileIndex) mutation, {
    required bool rethrowOnFailure,
    bool skipIfUnchanged = false,
    void Function(List<String> dropped)? onDropped,
  }) {
    late FileIndex result;
    return _enqueue(() async {
      final previous = state.index;
      final next = mutation(previous);
      if (skipIfUnchanged && identical(next, previous)) {
        result = previous;
        onDropped?.call(const []);
        return;
      }
      state = state.copyWith(index: next, isSaving: true, mutationError: null);
      try {
        final written = await _save(next);
        onDropped?.call(_lastDroppedDuplicates);
        state = state.copyWith(index: written, isSaving: false, stale: false);
        result = written;
      } catch (e) {
        // Roll back so the UI never shows state that isn't in Telegram.
        state = state.copyWith(index: previous, isSaving: false, mutationError: e.toString());
        result = previous;
        if (rethrowOnFailure) rethrow;
      }
    }).then((_) => result);
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
  Future<void> deleteItems(List<FileItem> files, List<String> folderIds) {
    if (files.isEmpty && folderIds.isEmpty) return Future.value();
    return _enqueue(() async {
      state = state.copyWith(isSaving: true, mutationError: null);
      try {
        if (files.isNotEmpty) {
          await _service.deleteFromTelegram(files);
        }
        var next = state.index;
        for (final f in files) {
          next = next.removeFile(f.id);
        }
        for (final id in folderIds) {
          next = next.removeFolder(id);
        }
        final written = await _save(next);
        state = state.copyWith(index: written, isSaving: false, stale: false);
        if (files.isNotEmpty) bumpDeviceState(_ref);
      } catch (e) {
        state = state.copyWith(isSaving: false, mutationError: e.toString());
      }
    });
  }

  /// One-time recovery: replaces the whole index with [merged] — see
  /// [FileIndex.merge] and [IndexService.findAllIndexSnapshots].
  Future<void> replaceIndex(FileIndex merged) => _mutate((_) => merged);

  Future<void> addFile(FileItem file) => _mutate((i) => i.addFile(file));

  /// Adds several files in one mutation, so bulk uploads write the index to
  /// Telegram once per batch instead of once per file (the per-file path made
  /// a large upload fire hundreds of editMessage round-trips, each subject to
  /// flood-wait).
  Future<void> addFiles(List<FileItem> files) {
    if (files.isEmpty) return Future.value();
    return _mutate((i) => i.addFiles(files));
  }

  Future<void> removeFile(String fileId) => _mutate((i) => i.removeFile(fileId));

  /// Hides [fileIds] from Gallery/Albums without deleting them — see
  /// [FileIndex.archiveFiles]. Optimistic like every other mutation here: the
  /// UI hides them immediately, and [_mutate] rolls back if the Telegram
  /// write fails. bumpDeviceState so Gallery's feed (which watches it) drops
  /// them from the grid right away instead of on the next unrelated bump.
  Future<void> archiveFiles(List<String> fileIds) {
    if (fileIds.isEmpty) return Future.value();
    return _mutate((i) => i.archiveFiles(fileIds)).then((_) => bumpDeviceState(_ref));
  }

  Future<void> unarchiveFiles(List<String> fileIds) {
    if (fileIds.isEmpty) return Future.value();
    return _mutate((i) => i.unarchiveFiles(fileIds)).then((_) => bumpDeviceState(_ref));
  }

  /// Permanently deletes [items] from Telegram and the index. Not optimistic:
  /// the index is only updated after Telegram confirms the deletion.
  Future<void> deleteFiles(List<FileItem> items) {
    if (items.isEmpty) return Future.value();
    return _enqueue(() async {
      state = state.copyWith(isSaving: true, mutationError: null);
      try {
        await _service.deleteFromTelegram(items);
        var next = state.index;
        for (final item in items) {
          next = next.removeFile(item.id);
        }
        final written = await _save(next);
        state = state.copyWith(index: written, isSaving: false, stale: false);
        bumpDeviceState(_ref);
      } catch (e) {
        state = state.copyWith(isSaving: false, mutationError: e.toString());
      }
    });
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
    StateNotifierProvider<IndexNotifier, IndexState>((ref) => IndexNotifier(ref));
