import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show DatabaseFactory;
import 'heartbeat.dart';
import 'registry_store.dart';

/// Persists which device asset IDs have been uploaded, which cloud file each
/// one became, where the local copy lives, and the small backup settings.
///
/// Backed by an in-memory mirror (so every getter stays synchronous) that is
/// loaded once at [init] from `tv_registry.db` and written through to it. The
/// store used to be SharedPreferences (4 keys per asset, whole-file rewrite on
/// every write); see registry_store.dart for the storage and the one-time,
/// verified migration. Liveness heartbeats live in small files (heartbeat.dart).
///
/// Works in every isolate/engine of the process (UI, headless WorkManager):
/// each has its own mirror; [reload] pulls what the others wrote.
class BackupRegistry {
  static final instance = BackupRegistry._();
  BackupRegistry._();

  /// A registry with injected storage location, database factory and
  /// preferences — tests only.
  @visibleForTesting
  BackupRegistry.forTesting({
    required String dir,
    DatabaseFactory? factory,
    SharedPreferences? prefs,
    int? simulateCrashAfterRemovals,
  })  : _dirOverride = dir,
        _factoryOverride = factory,
        _prefsOverride = prefs,
        // ignore: prefer_initializing_formals
        _simulateCrashAfterRemovals = simulateCrashAfterRemovals;

  String? _dirOverride;
  DatabaseFactory? _factoryOverride;
  SharedPreferences? _prefsOverride;
  int? _simulateCrashAfterRemovals;

  RegistryStorage? _storage;
  Future<void>? _initFuture;
  bool _usingPrefsFallback = false;

  // In-memory mirror.
  final Set<String> _uploaded = {};
  final Map<String, String> _fileForAsset = {};
  final Map<String, String> _assetForFile = {};
  final Map<String, String> _pathForFile = {};
  final Map<String, String> _kv = {};
  List<String> _enabled = const [];

  /// True when the database could not be used and this isolate runs on the
  /// legacy SharedPreferences layout (data untouched). Diagnostic only.
  bool get usingPrefsFallback => _usingPrefsFallback;

  /// Result of the migration attempt made by this isolate's [init], if any.
  MigrationResult? lastMigration;

  /// On-device benchmarks only: points this (singleton) registry at a scratch
  /// directory BEFORE the first [init], so a synthetic run never opens the
  /// owner's real `tv_registry.db` (opening it would run the prefs migration
  /// against the benchmark's empty preferences and mark it done).
  @visibleForTesting
  void debugUseDirectory(String dir) {
    if (_initFuture != null) {
      throw StateError('debugUseDirectory must be called before init()');
    }
    _dirOverride = dir;
  }

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final f = _init();
    _initFuture = f;
    unawaited(f.catchError((Object _) {
      if (identical(_initFuture, f)) _initFuture = null;
    }));
    return f;
  }

  Future<void> _init() async {
    final dir = await _resolveDir();
    Heartbeat.configure(dir);

    final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
    RegistryStore? store;
    try {
      store = await RegistryStore.open(
          factory: _factoryOverride, path: p.join(dir, 'tv_registry.db'));
      final result = await store.migrateFromPrefs(
        prefs,
        backupPath: p.join(dir, 'tv_registry_prefs_backup.json'),
        simulateCrashAfterRemovals: _simulateCrashAfterRemovals,
      );
      lastMigration = result;
      debugPrint('TVDIAG: registry $result');
      if (result.status == MigrationStatus.failed) {
        await store.close();
        store = null;
      }
    } catch (e) {
      if (_simulateCrashAfterRemovals != null) {
        await store?.close();
        rethrow;
      }
      debugPrint('TVDIAG: registry db unavailable (${e.runtimeType}), '
          'using preferences');
      try {
        await store?.close();
      } catch (_) {}
      store = null;
    }

    if (store != null) {
      _storage = store;
      _usingPrefsFallback = false;
    } else {
      _storage = PrefsRegistryStorage(prefs);
      _usingPrefsFallback = true;
    }
    _applySnapshot(await _storage!.load());
  }

  Future<String> _resolveDir() async {
    final override = _dirOverride;
    if (override != null) return override;
    try {
      return (await getApplicationSupportDirectory()).path;
    } catch (_) {
      final d = Directory(p.join(Directory.systemTemp.path, 'televault'));
      await d.create(recursive: true);
      return d.path;
    }
  }

  /// Releases the database (tests, and when an isolate is torn down).
  Future<void> close() async {
    final s = _storage;
    _storage = null;
    _initFuture = null;
    await s?.close();
  }

  void _ensure() => _s;

  RegistryStorage get _s {
    final s = _storage;
    if (s == null) {
      throw StateError('BackupRegistry.init() has not completed');
    }
    return s;
  }

  // -- mirror ---------------------------------------------------------------

  void _applySnapshot(RegistrySnapshot snap) {
    if (snap.full) {
      _uploaded.clear();
      _fileForAsset.clear();
      _assetForFile.clear();
      _pathForFile.clear();
    }
    for (final r in snap.links) {
      _applyLink(r.assetId, r.fileId, r.uploaded);
    }
    _pathForFile.addAll(snap.paths);
    _kv
      ..clear()
      ..addAll(snap.kv);
    _enabled = _decodeList(_kv[RegistryKeys.enabledAlbums]);
  }

  void _applyLink(String assetId, String? fileId, bool uploaded) {
    if (uploaded) {
      _uploaded.add(assetId);
    } else {
      _uploaded.remove(assetId);
    }
    final old = _fileForAsset[assetId];
    if (old != null && old != fileId && _assetForFile[old] == assetId) {
      _assetForFile.remove(old);
    }
    if (fileId != null) {
      _fileForAsset[assetId] = fileId;
      _assetForFile[fileId] = assetId;
    } else {
      _fileForAsset.remove(assetId);
    }
  }

  static List<String> _decodeList(String? json) {
    if (json == null) return const [];
    try {
      return (jsonDecode(json) as List).map((e) => '$e').toList();
    } catch (_) {
      return const [];
    }
  }

  /// Re-reads what other isolates (the headless task) changed since the last
  /// load, so this isolate's mirror converges with the database.
  Future<void> reload() async {
    await init();
    _applySnapshot(await _s.loadChanges());
  }

  // -- uploaded / links -----------------------------------------------------

  bool isUploaded(String assetId) {
    _ensure();
    return _uploaded.contains(assetId);
  }

  Future<void> markUploaded(String assetId) async {
    await _s.markUploaded(assetId);
    _uploaded.add(assetId);
  }

  /// Clears the "uploaded" flag — used when an asset is found marked
  /// uploaded but with no matching entry in the actual index (e.g. the app
  /// was killed between marking it uploaded and linking it to its file, or
  /// between uploading and the index write actually persisting). Treating it
  /// as not-yet-uploaded again is the safe default: it gets excluded from
  /// "free up storage" candidates and picked up by the next backup pass
  /// instead of silently trusting a link that was never confirmed.
  Future<void> clearUploaded(String assetId) async {
    await _s.clearUploaded(assetId);
    _uploaded.remove(assetId);
  }

  /// All device asset ids known to already be backed up to Telegram — used to
  /// find candidates for freeing up local storage.
  Set<String> get uploadedAssetIds {
    _ensure();
    return Set<String>.of(_uploaded);
  }

  /// Records that the uploaded [fileItemId] originated from the local file at
  /// [localPath], so it can be recognized as already-on-device even though it
  /// was never explicitly "saved" via the download action.
  Future<void> linkLocalPath(String fileItemId, String localPath) async {
    await _s.linkPath(fileItemId, localPath);
    _pathForFile[fileItemId] = localPath;
  }

  String? localPathFor(String fileItemId) {
    _ensure();
    return _pathForFile[fileItemId];
  }

  /// Records which [FileItem] id a device [assetId] was uploaded as, so an
  /// already-uploaded device photo can be added to a vault album (which is
  /// keyed by file id, not device asset id) without re-uploading it. Also
  /// records the reverse link, so a cloud FileItem can find its device asset
  /// (e.g. to offer "delete from device too").
  Future<void> linkFileItem(String assetId, String fileItemId) async {
    await _s.linkFile(assetId, fileItemId);
    _applyLink(assetId, fileItemId, _uploaded.contains(assetId));
  }

  String? fileItemIdFor(String assetId) {
    _ensure();
    return _fileForAsset[assetId];
  }

  String? assetIdForFileItem(String fileItemId) {
    _ensure();
    return _assetForFile[fileItemId];
  }

  /// Records a batch of finished uploads (uploaded flag + file link + local
  /// path for each) in ONE database transaction. Use this from flush paths
  /// instead of three awaited calls per file.
  Future<void> commitUploads(
      List<({String assetId, String fileItemId, String path})> items) async {
    if (items.isEmpty) return;
    await _s.commitUploads(items);
    for (final it in items) {
      _uploaded.add(it.assetId);
      _applyLink(it.assetId, it.fileItemId, true);
      _pathForFile[it.fileItemId] = it.path;
    }
  }

  /// Clears every registry entry tied to a cloud file that's being deleted
  /// from Telegram: the fileItem→path link, the fileItem↔asset links, and —
  /// critically — the "uploaded" flag on its device asset (if any). Without
  /// this, a deleted-from-Telegram file's original device asset keeps
  /// reporting as "safely backed up", so auto-backup never re-uploads it and
  /// Free Up Storage can offer to delete its last remaining copy.
  Future<void> unlinkFileItem(String fileItemId) async {
    final removed = await _s.unlinkFile(fileItemId);
    _pathForFile.remove(fileItemId);
    final mirrored = _assetForFile.remove(fileItemId);
    for (final a in {...removed, ?mirrored}) {
      _fileForAsset.remove(a);
      _uploaded.remove(a);
    }
  }

  // -- uploaded, not yet indexed -------------------------------------------

  /// Records an upload that reached Telegram before its index write (see
  /// [PendingIndexRow]). Written right after the upload, before any flush, so
  /// a failed or interrupted index write never makes the asset look pending
  /// again: [isPendingIndex] keeps it from being uploaded a second time and
  /// the next flush/run indexes it from here.
  Future<void> addPendingIndex({
    required String assetId,
    required String fileItemId,
    required String itemJson,
    required String path,
  }) async {
    await init();
    await _s.addPendingIndex(
        (assetId: assetId, fileItemId: fileItemId, itemJson: itemJson, path: path));
  }

  /// Every upload still waiting for its index write, oldest first.
  Future<List<PendingIndexRow>> pendingIndex() async {
    await init();
    return _s.pendingIndex();
  }

  /// Asset ids of [pendingIndex].
  Future<Set<String>> pendingIndexAssetIds() async =>
      {for (final r in await pendingIndex()) r.assetId};

  /// True when [assetId] was uploaded and only its index write is pending:
  /// it must not be uploaded again.
  Future<bool> isPendingIndex(String assetId) async =>
      (await pendingIndexAssetIds()).contains(assetId);

  /// Drops the rows of uploads that are now in the written index (and linked).
  Future<void> removePendingIndex(List<String> fileItemIds) async {
    if (fileItemIds.isEmpty) return;
    await init();
    await _s.removePendingIndex(fileItemIds);
  }

  // -- settings -------------------------------------------------------------

  /// Whether automatic backup (album auto-sync, and the on-device-change
  /// watcher) is allowed to run over mobile data. Off by default — automatic
  /// uploads only happen on WiFi unless the user opts in. Doesn't affect
  /// explicit user actions (e.g. tapping "Upload" in Gallery), only the
  /// automatic paths in [BackupNotifier].
  bool get allowMobileData {
    _ensure();
    return _kv[RegistryKeys.allowMobileData] == '1';
  }

  Future<void> setAllowMobileData(bool value) async {
    final v = LegacyRegistry.encodeBool(value);
    await _s.setKvMany({RegistryKeys.allowMobileData: v});
    _kv[RegistryKeys.allowMobileData] = v;
  }

  List<String> get enabledAlbumIds {
    _ensure();
    return List<String>.of(_enabled);
  }

  bool isAlbumEnabled(String albumId) => enabledAlbumIds.contains(albumId);

  Future<void> setAlbumEnabled(String albumId, {required bool enabled}) async {
    final current = enabledAlbumIds;
    List<String>? next;
    if (enabled && !current.contains(albumId)) {
      next = [...current, albumId];
    } else if (!enabled && current.contains(albumId)) {
      next = current.where((id) => id != albumId).toList();
    }
    if (next == null) return;
    final json = jsonEncode(next);
    await _s.setKvMany({RegistryKeys.enabledAlbums: json});
    _kv[RegistryKeys.enabledAlbums] = json;
    _enabled = next;
  }

  /// What the last headless background run did, so a "nothing uploads with the
  /// app closed" report can be diagnosed from inside the app (no logcat): a
  /// stale timestamp means the OS isn't running the task at all (battery
  /// restrictions), a fresh one with a skip/failure status says exactly why.
  Future<void> recordHeadlessRun(String status) async {
    final ms = '${DateTime.now().millisecondsSinceEpoch}';
    await _s.setKvMany({
      RegistryKeys.headlessRunMs: ms,
      RegistryKeys.headlessStatus: status,
    });
    _kv[RegistryKeys.headlessRunMs] = ms;
    _kv[RegistryKeys.headlessStatus] = status;
  }

  ({DateTime at, String status})? get lastHeadlessRun {
    _ensure();
    final ms = int.tryParse(_kv[RegistryKeys.headlessRunMs] ?? '');
    if (ms == null) return null;
    return (
      at: DateTime.fromMillisecondsSinceEpoch(ms),
      status: _kv[RegistryKeys.headlessStatus] ?? '',
    );
  }

  // -- heartbeats (files, see heartbeat.dart) -------------------------------

  /// Marks the in-app transfer queue as actively working right now.
  ///
  /// The headless periodic background task (see headless_sync.dart) checks
  /// [queueRecentlyActive] before starting its own upload connection — two
  /// independent connections uploading to the same account at once is what
  /// corrupted the Telegram session earlier in this app's life (see
  /// UploadService's single-connection serialization, which only protects
  /// callers *within* one process; the background task runs in a separate
  /// one, so that alone doesn't cover it here).
  Future<void> markQueueHeartbeat() async {
    await init();
    await Heartbeat.touch('queue');
  }

  /// True if the in-app queue reported activity within the last 45s — long
  /// enough to comfortably span the gap between two items in a normal
  /// upload, short enough that a stale heartbeat from a crashed run doesn't
  /// block the background task forever.
  bool get queueRecentlyActive =>
      Heartbeat.isFresh('queue', const Duration(seconds: 45));

  /// Marks the logged-in app process as alive right now (MainShell calls this
  /// every ~20s for as long as it's mounted; the write is throttled to once
  /// per 15 s).
  ///
  /// [queueRecentlyActive] only covers the queue while it's mid-upload, but
  /// a live app owns uploads the whole time: its device-change watcher and
  /// auto-sync can start the queue at any moment. A headless run starting in
  /// that gap ran its own upload connection alongside the app's (both seen
  /// uploading at once in the log) — CPU-heavy pure-Dart encryption twice
  /// over on a memory-starved phone, and the two-connection pattern that has
  /// corrupted the session before.
  Future<void> markAppAlive() async {
    await init();
    await Heartbeat.touch('app');
  }

  /// True if the app process reported itself alive within the last 60s —
  /// three missed heartbeats, so a slow frame or two doesn't count as dead,
  /// while a killed process stops blocking the background task within a
  /// minute.
  bool get appRecentlyAlive =>
      Heartbeat.isFresh('app', const Duration(seconds: 60));
}
