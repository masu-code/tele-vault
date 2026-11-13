import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// Storage layer of `BackupRegistry`.
///
/// Two implementations of [RegistryStorage]:
///  * [RegistryStore] — sqflite database `tv_registry.db` (the normal path);
///  * [PrefsRegistryStorage] — the legacy SharedPreferences layout, used ONLY
///    as a safety net when the database cannot be opened or the one-time
///    migration cannot be verified (the prefs are then left untouched).
///
/// Logs carry counts only, never asset ids, file names or paths.

/// Keys of the small settings kept in `kv` (same names as the legacy prefs).
class RegistryKeys {
  RegistryKeys._();
  static const enabledAlbums = 'bk_enabled_albums';
  static const allowMobileData = 'bk_allow_mobile_data';
  static const headlessRunMs = 'bk_headless_run_ms';
  static const headlessStatus = 'bk_headless_status';

  /// Telegram user id the registry's links belong to (see
  /// `BackupRegistry.bindAccount`). Deliberately not a `bk_` key: it is not
  /// part of the legacy SharedPreferences layout.
  static const account = 'tv_account';

  // Legacy-only keys (SharedPreferences).
  static const uploadedPrefix = 'bk_up_';
  static const linkPrefix = 'bk_link_';
  static const fileItemPrefix = 'bk_item_';
  static const assetForFileItemPrefix = 'bk_asset_';
  static const legacyQueueHeartbeat = 'bk_queue_heartbeat_ms';
  static const legacyAppAlive = 'bk_app_alive_ms';

  static const migratedFlag = 'migrated_v1';
  static const cleanedFlag = 'prefs_cleaned_v1';

  static bool isLegacyKey(String k) =>
      k.startsWith(uploadedPrefix) ||
      k.startsWith(linkPrefix) ||
      k.startsWith(fileItemPrefix) ||
      k.startsWith(assetForFileItemPrefix) ||
      k == enabledAlbums ||
      k == allowMobileData ||
      k == headlessRunMs ||
      k == headlessStatus ||
      k == legacyQueueHeartbeat ||
      k == legacyAppAlive;
}

/// One row of the asset table: whether [assetId] is uploaded and which file
/// item it was uploaded as.
class LinkRow {
  const LinkRow(this.assetId, this.fileId, this.uploaded);
  final String assetId;
  final String? fileId;
  final bool uploaded;
}

/// Rows read from storage. [full] = the mirror must be rebuilt from scratch;
/// otherwise the rows are changes to apply on top of the current mirror.
/// [kv] is always the complete settings table (it is tiny).
class RegistrySnapshot {
  RegistrySnapshot({required this.full});
  final bool full;
  final List<LinkRow> links = [];
  final Map<String, String> paths = {};
  final Map<String, String> kv = {};
}

typedef UploadCommit = ({String assetId, String fileItemId, String path});

/// An upload that reached Telegram but is not in the written index yet:
/// [itemJson] is the full `FileItem.toJson()` (encoded), [path] the local
/// file it came from. Kept until a save puts the item in the index, so the
/// asset is never uploaded a second time because an index write failed.
typedef PendingIndexRow = ({
  String assetId,
  String fileItemId,
  String itemJson,
  String path,
});

/// A [PendingIndexRow] with the Telegram user id of the account that
/// uploaded it (null for rows written before accounts were recorded).
typedef TaggedPendingRow = ({PendingIndexRow row, int? account});

abstract class RegistryStorage {
  Future<RegistrySnapshot> load();

  /// Changes made by another writer since the last load/loadChanges.
  Future<RegistrySnapshot> loadChanges();

  Future<void> markUploaded(String assetId);
  Future<void> clearUploaded(String assetId);
  Future<void> linkPath(String fileId, String path);
  Future<void> linkFile(String assetId, String fileId);

  /// Removes the path link, the asset link(s) and the uploaded flag(s) tied
  /// to [fileId]. Returns the asset ids whose rows were removed.
  Future<List<String>> unlinkFile(String fileId);

  /// markUploaded + linkFile + linkPath for every item in ONE transaction.
  Future<void> commitUploads(List<UploadCommit> items);

  Future<void> setKvMany(Map<String, String> entries);

  /// Uploads waiting for their index write (see [PendingIndexRow]). Read
  /// straight from storage (not mirrored), so every isolate sees the rows the
  /// others wrote.
  ///
  /// [account] tags the row with the uploader's Telegram user id.
  Future<void> addPendingIndex(PendingIndexRow row, {int? account});
  Future<List<PendingIndexRow>> pendingIndex();

  /// Every pending row with its account tag.
  Future<List<TaggedPendingRow>> pendingIndexTagged();

  /// Tags the rows that have no account yet with [account].
  Future<void> tagUntaggedPendingIndex(int account);
  Future<void> removePendingIndex(List<String> fileItemIds);

  /// Removes every asset link, uploaded flag and local-path link (all
  /// accounts' pending-index rows and the settings stay). Other isolates see
  /// it as a deletion and reload fully.
  Future<void> clearLinks();

  Future<void> close();
}

// ---------------------------------------------------------------------------
// Legacy parse (SharedPreferences)
// ---------------------------------------------------------------------------

/// Everything the old SharedPreferences layout held, parsed.
class LegacyRegistry {
  final Set<String> uploaded = {};
  final Map<String, String> items = {}; // assetId -> fileItemId
  final Map<String, String> paths = {}; // fileItemId -> local path
  final Map<String, String> kv = {};
  final Map<String, Object?> rawEntries = {}; // every bk_* entry, for backup
  int recognizedKeys = 0;
  int reconstructedLinks = 0;

  bool get isEmpty => recognizedKeys == 0;

  /// Parses every `bk_*` key. Throws [FormatException] when a recognised key
  /// has an unexpected type: the caller treats that as "do not migrate".
  static LegacyRegistry parse(SharedPreferences prefs) {
    final out = LegacyRegistry();
    final reverse = <String, String>{}; // fileItemId -> assetId (bk_asset_)
    for (final key in prefs.getKeys()) {
      if (!key.startsWith('bk_')) continue;
      final value = prefs.get(key);
      out.rawEntries[key] = value;
      if (!RegistryKeys.isLegacyKey(key)) continue;
      out.recognizedKeys++;

      String str() {
        if (value is String) return value;
        throw FormatException('legacy key has unexpected type');
      }

      if (key.startsWith(RegistryKeys.uploadedPrefix)) {
        if (value is! bool) {
          throw const FormatException('legacy key has unexpected type');
        }
        if (value) {
          out.uploaded.add(key.substring(RegistryKeys.uploadedPrefix.length));
        }
      } else if (key.startsWith(RegistryKeys.fileItemPrefix)) {
        out.items[key.substring(RegistryKeys.fileItemPrefix.length)] = str();
      } else if (key.startsWith(RegistryKeys.linkPrefix)) {
        out.paths[key.substring(RegistryKeys.linkPrefix.length)] = str();
      } else if (key.startsWith(RegistryKeys.assetForFileItemPrefix)) {
        reverse[key.substring(RegistryKeys.assetForFileItemPrefix.length)] =
            str();
      } else if (key == RegistryKeys.enabledAlbums) {
        if (value is! List) {
          throw const FormatException('legacy key has unexpected type');
        }
        out.kv[key] = jsonEncode(value.map((e) => '$e').toList());
      } else if (key == RegistryKeys.allowMobileData) {
        if (value is! bool) {
          throw const FormatException('legacy key has unexpected type');
        }
        out.kv[key] = encodeBool(value);
      } else if (key == RegistryKeys.headlessRunMs) {
        if (value is! int) {
          throw const FormatException('legacy key has unexpected type');
        }
        out.kv[key] = '$value';
      } else if (key == RegistryKeys.headlessStatus) {
        out.kv[key] = str();
      }
      // legacyQueueHeartbeat / legacyAppAlive: stale liveness values, counted
      // as recognised (they get cleaned) but not migrated.
    }
    // A reverse link whose forward link is missing: rebuild the forward link
    // so no link record is lost (stale reverse links are never invented:
    // putIfAbsent only fills a gap).
    reverse.forEach((fileId, assetId) {
      if (!out.items.containsKey(assetId)) {
        out.items[assetId] = fileId;
        out.reconstructedLinks++;
      }
    });
    return out;
  }

  static String encodeBool(bool v) => v ? '1' : '0';
}

// ---------------------------------------------------------------------------
// SQLite implementation
// ---------------------------------------------------------------------------

enum MigrationStatus { alreadyDone, nothingToMigrate, migrated, failed }

class MigrationResult {
  const MigrationResult(
    this.status, {
    this.uploaded = 0,
    this.links = 0,
    this.paths = 0,
    this.detail,
  });
  final MigrationStatus status;
  final int uploaded;
  final int links;
  final int paths;
  final String? detail;

  @override
  String toString() =>
      'migration ${status.name} uploaded=$uploaded links=$links paths=$paths'
      '${detail == null ? '' : ' ($detail)'}';
}

class _Rev {
  _Rev(this._v);
  final int _v;
  bool used = false;
  bool deleted = false;
  int get value {
    used = true;
    return _v;
  }

  void markDeleted() {
    used = true;
    deleted = true;
  }
}

class _AlreadyMigrated implements Exception {}

class RegistryStore implements RegistryStorage {
  RegistryStore._(this._db);

  final Database _db;

  // Highest `rev` seen by this instance, and the deletion counter it last
  // observed (a deletion cannot be seen as a changed row, so it forces a full
  // reload instead).
  int _watermark = 0;
  int _seenDelRev = 0;

  static const _revKey = '_rev';
  static const _delRevKey = '_del_rev';

  /// Opens (creating if needed) the registry database at [path].
  static Future<RegistryStore> open({
    DatabaseFactory? factory,
    required String path,
  }) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          try {
            await db.rawQuery('PRAGMA busy_timeout = 5000');
          } catch (_) {}
        },
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE IF NOT EXISTS links('
              'asset_id TEXT PRIMARY KEY, file_id TEXT, '
              'uploaded INTEGER NOT NULL DEFAULT 0, '
              'rev INTEGER NOT NULL DEFAULT 0)');
          await db.execute(
              'CREATE INDEX IF NOT EXISTS links_file_id ON links(file_id)');
          await db
              .execute('CREATE INDEX IF NOT EXISTS links_rev ON links(rev)');
          // The local path is keyed by the FILE ITEM id (uploads that did not
          // come from a device asset have a path but no asset).
          await db.execute('CREATE TABLE IF NOT EXISTS paths('
              'file_id TEXT PRIMARY KEY, local_path TEXT NOT NULL, '
              'rev INTEGER NOT NULL DEFAULT 0)');
          await db
              .execute('CREATE INDEX IF NOT EXISTS paths_rev ON paths(rev)');
          await db.execute(
              'CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)');
        },
        // Not a version bump: CREATE IF NOT EXISTS on every open adds the
        // table to databases created before it, and an older build opening
        // this database just ignores it.
        onOpen: _createPendingIndexTable,
      ),
    );
    return RegistryStore._(db);
  }

  static Future<void> _createPendingIndexTable(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS pending_index('
        'file_id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, '
        'item_json TEXT NOT NULL, local_path TEXT NOT NULL, '
        'created_ms INTEGER NOT NULL, account INTEGER)');
    await db.execute('CREATE INDEX IF NOT EXISTS pending_index_asset '
        'ON pending_index(asset_id)');
    // Tables created before accounts were recorded lack the column. Added in
    // place (no version bump); an older build keeps working on it, since its
    // statements name their columns.
    // Two engines (the app and a WorkManager one) can open the database on
    // the same first launch: both see the column missing and the second ALTER
    // throws "duplicate column". Re-check the schema before giving up.
    if (!await _hasAccountColumn(db)) {
      try {
        await db
            .execute('ALTER TABLE pending_index ADD COLUMN account INTEGER');
      } catch (_) {
        if (!await _hasAccountColumn(db)) rethrow;
      }
    }
  }

  static Future<bool> _hasAccountColumn(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info(pending_index)');
    return cols.any((c) => c['name'] == 'account');
  }

  @override
  Future<void> close() => _db.close();

  // -- low level helpers ----------------------------------------------------

  Future<String?> _kvGet(DatabaseExecutor ex, String k) async {
    final rows = await ex.rawQuery('SELECT v FROM kv WHERE k = ?', [k]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  Future<void> _kvPut(DatabaseExecutor ex, String k, String v) async {
    await ex.rawInsert('INSERT OR REPLACE INTO kv(k, v) VALUES(?, ?)', [k, v]);
  }

  Future<String?> readKv(String k) => _kvGet(_db, k);

  Future<T> _write<T>(Future<T> Function(Transaction txn, _Rev rev) body) {
    return _db.transaction((txn) async {
      final cur = int.tryParse(await _kvGet(txn, _revKey) ?? '') ?? 0;
      final rev = _Rev(cur + 1);
      final out = await body(txn, rev);
      if (rev.used) {
        await _kvPut(txn, _revKey, '${rev.value}');
        if (rev.deleted) await _kvPut(txn, _delRevKey, '${rev.value}');
      }
      return out;
    });
  }

  Future<void> _upsertLink(
    Transaction txn,
    _Rev rev,
    String assetId, {
    String? fileId,
    bool setFile = false,
    bool? uploaded,
  }) async {
    final rows = await txn.rawQuery(
        'SELECT file_id, uploaded FROM links WHERE asset_id = ?', [assetId]);
    final exists = rows.isNotEmpty;
    final oldFile = exists ? rows.first['file_id'] as String? : null;
    final oldUp = exists && (rows.first['uploaded'] as int) != 0;
    final newFile = setFile ? fileId : oldFile;
    final newUp = uploaded ?? oldUp;
    if (exists && newFile == oldFile && newUp == oldUp) return;
    // REPLACE (not UPDATE) is fine: `rev` is what readers watch.
    await txn.rawInsert(
        'INSERT OR REPLACE INTO links(asset_id, file_id, uploaded, rev) '
        'VALUES(?, ?, ?, ?)',
        [assetId, newFile, newUp ? 1 : 0, rev.value]);
  }

  Future<void> _upsertPath(
      Transaction txn, _Rev rev, String fileId, String path) async {
    final rows = await txn.rawQuery(
        'SELECT local_path FROM paths WHERE file_id = ?', [fileId]);
    if (rows.isNotEmpty && rows.first['local_path'] == path) return;
    await txn.rawInsert(
        'INSERT OR REPLACE INTO paths(file_id, local_path, rev) '
        'VALUES(?, ?, ?)',
        [fileId, path, rev.value]);
  }

  // -- writes ---------------------------------------------------------------

  @override
  Future<void> markUploaded(String assetId) => _write(
      (txn, rev) => _upsertLink(txn, rev, assetId, uploaded: true));

  @override
  Future<void> clearUploaded(String assetId) => _write((txn, rev) async {
        final rows = await txn.rawQuery(
            'SELECT file_id FROM links WHERE asset_id = ?', [assetId]);
        if (rows.isEmpty) return;
        if (rows.first['file_id'] == null) {
          await txn
              .rawDelete('DELETE FROM links WHERE asset_id = ?', [assetId]);
          rev.markDeleted();
        } else {
          await _upsertLink(txn, rev, assetId, uploaded: false);
        }
      });

  @override
  Future<void> linkPath(String fileId, String path) =>
      _write((txn, rev) => _upsertPath(txn, rev, fileId, path));

  @override
  Future<void> linkFile(String assetId, String fileId) => _write((txn, rev) =>
      _upsertLink(txn, rev, assetId, fileId: fileId, setFile: true));

  @override
  Future<List<String>> unlinkFile(String fileId) => _write((txn, rev) async {
        final rows = await txn.rawQuery(
            'SELECT asset_id FROM links WHERE file_id = ?', [fileId]);
        final assets = rows.map((r) => r['asset_id'] as String).toList();
        final delLinks =
            await txn.rawDelete('DELETE FROM links WHERE file_id = ?', [fileId]);
        final delPaths =
            await txn.rawDelete('DELETE FROM paths WHERE file_id = ?', [fileId]);
        if (delLinks > 0 || delPaths > 0) {
          rev.markDeleted();
        }
        return assets;
      });

  @override
  Future<void> commitUploads(List<UploadCommit> items) {
    if (items.isEmpty) return Future.value();
    return _write((txn, rev) async {
      for (final it in items) {
        await _upsertLink(txn, rev, it.assetId,
            fileId: it.fileItemId, setFile: true, uploaded: true);
        await _upsertPath(txn, rev, it.fileItemId, it.path);
      }
    });
  }

  @override
  Future<void> setKvMany(Map<String, String> entries) {
    if (entries.isEmpty) return Future.value();
    return _db.transaction((txn) async {
      for (final e in entries.entries) {
        await _kvPut(txn, e.key, e.value);
      }
    });
  }

  @override
  Future<void> addPendingIndex(PendingIndexRow row, {int? account}) =>
      _db.rawInsert(
          'INSERT OR REPLACE INTO pending_index'
          '(file_id, asset_id, item_json, local_path, created_ms, account) '
          'VALUES(?, ?, ?, ?, ?, ?)',
          [
            row.fileItemId,
            row.assetId,
            row.itemJson,
            row.path,
            DateTime.now().millisecondsSinceEpoch,
            account,
          ]);

  @override
  Future<List<TaggedPendingRow>> pendingIndexTagged() async {
    final rows = await _db.rawQuery(
        'SELECT file_id, asset_id, item_json, local_path, account '
        'FROM pending_index ORDER BY created_ms, rowid');
    return [
      for (final r in rows)
        (
          row: (
            assetId: r['asset_id'] as String,
            fileItemId: r['file_id'] as String,
            itemJson: r['item_json'] as String,
            path: r['local_path'] as String,
          ),
          account: r['account'] as int?,
        ),
    ];
  }

  @override
  Future<void> tagUntaggedPendingIndex(int account) => _db.rawUpdate(
      'UPDATE pending_index SET account = ? WHERE account IS NULL', [account]);

  @override
  Future<void> clearLinks() => _write((txn, rev) async {
        final delLinks = await txn.rawDelete('DELETE FROM links');
        final delPaths = await txn.rawDelete('DELETE FROM paths');
        if (delLinks > 0 || delPaths > 0) rev.markDeleted();
      });

  @override
  Future<List<PendingIndexRow>> pendingIndex() async {
    final rows = await _db.rawQuery(
        'SELECT file_id, asset_id, item_json, local_path FROM pending_index '
        'ORDER BY created_ms, rowid');
    return [
      for (final r in rows)
        (
          assetId: r['asset_id'] as String,
          fileItemId: r['file_id'] as String,
          itemJson: r['item_json'] as String,
          path: r['local_path'] as String,
        ),
    ];
  }

  @override
  Future<void> removePendingIndex(List<String> fileItemIds) {
    if (fileItemIds.isEmpty) return Future.value();
    return _db.transaction((txn) async {
      for (final id in fileItemIds) {
        await txn.rawDelete('DELETE FROM pending_index WHERE file_id = ?', [id]);
      }
    });
  }

  // -- reads ----------------------------------------------------------------

  Future<RegistrySnapshot> _read(DatabaseExecutor ex, {required bool full}) async {
    final snap = RegistrySnapshot(full: full);
    final where = full ? '' : ' WHERE rev > $_watermark';
    final linkRows = await ex.rawQuery(
        'SELECT asset_id, file_id, uploaded, rev FROM links$where '
        'ORDER BY rev, rowid');
    final pathRows = await ex.rawQuery(
        'SELECT file_id, local_path, rev FROM paths$where ORDER BY rev, rowid');
    final kvRows = await ex.rawQuery('SELECT k, v FROM kv');
    var maxRev = full ? 0 : _watermark;
    for (final r in linkRows) {
      snap.links.add(LinkRow(r['asset_id'] as String, r['file_id'] as String?,
          (r['uploaded'] as int) != 0));
      final rev = r['rev'] as int;
      if (rev > maxRev) maxRev = rev;
    }
    for (final r in pathRows) {
      snap.paths[r['file_id'] as String] = r['local_path'] as String;
      final rev = r['rev'] as int;
      if (rev > maxRev) maxRev = rev;
    }
    for (final r in kvRows) {
      final k = r['k'] as String;
      final v = r['v'] as String?;
      if (v != null) snap.kv[k] = v;
    }
    _watermark = maxRev;
    _seenDelRev = int.tryParse(snap.kv[_delRevKey] ?? '') ?? 0;
    return snap;
  }

  @override
  Future<RegistrySnapshot> load() =>
      _db.transaction((txn) => _read(txn, full: true));

  @override
  Future<RegistrySnapshot> loadChanges() => _db.transaction((txn) async {
        final delRev = int.tryParse(await _kvGet(txn, _delRevKey) ?? '') ?? 0;
        return _read(txn, full: delRev != _seenDelRev);
      });

  // -- migration ------------------------------------------------------------

  /// One-time, crash-safe migration of the legacy SharedPreferences registry.
  ///
  /// Order of operations (every step is safe to interrupt):
  ///  1. parse every `bk_*` key (a key with an unexpected type aborts);
  ///  2. write a JSON backup of ALL `bk_*` entries to [backupPath] (atomic,
  ///     re-read and counted) — kept after the migration, never deleted;
  ///  3. ONE database transaction: insert everything, read it back and compare
  ///     it row by row and by count with what was parsed, and only then set
  ///     `migrated_v1`. Any mismatch rolls the transaction back, leaves the
  ///     prefs untouched and returns [MigrationStatus.failed];
  ///  4. only after the commit: remove the migrated `bk_*` keys (yielding to
  ///     the event loop every [removalYield] removals), then set
  ///     `prefs_cleaned_v1`.
  /// A crash in step 4 leaves a complete database (flag already set) plus
  /// leftover prefs keys that the next run just removes. Prefs keys that are
  /// not recognised are never removed.
  Future<MigrationResult> migrateFromPrefs(
    SharedPreferences prefs, {
    required String backupPath,
    int removalYield = 200,
    int? simulateCrashAfterRemovals, // tests only
  }) async {
    try {
      await prefs.reload();
    } catch (_) {}

    if (await readKv(RegistryKeys.migratedFlag) == '1') {
      await _cleanupPrefs(prefs, removalYield, simulateCrashAfterRemovals);
      return const MigrationResult(MigrationStatus.alreadyDone);
    }

    final LegacyRegistry legacy;
    try {
      legacy = LegacyRegistry.parse(prefs);
    } on FormatException catch (e) {
      return MigrationResult(MigrationStatus.failed, detail: e.message);
    }

    if (legacy.isEmpty) {
      await _db.transaction((txn) async {
        await _kvPut(txn, RegistryKeys.migratedFlag, '1');
        await _kvPut(txn, RegistryKeys.cleanedFlag, '1');
      });
      return const MigrationResult(MigrationStatus.nothingToMigrate);
    }

    // 2. backup first.
    try {
      await _writeBackup(legacy, backupPath);
    } catch (e) {
      return MigrationResult(MigrationStatus.failed,
          detail: 'backup failed: ${e.runtimeType}');
    }

    // 3. copy + verify + flag, atomically.
    final assetIds = <String>{...legacy.uploaded, ...legacy.items.keys};
    try {
      await _db.transaction((txn) async {
        if (await _kvGet(txn, RegistryKeys.migratedFlag) == '1') {
          throw _AlreadyMigrated();
        }
        final batch = txn.batch();
        for (final a in assetIds) {
          batch.rawInsert(
              'INSERT OR REPLACE INTO links(asset_id, file_id, uploaded, rev) '
              'VALUES(?, ?, ?, 1)',
              [a, legacy.items[a], legacy.uploaded.contains(a) ? 1 : 0]);
        }
        legacy.paths.forEach((f, p) {
          batch.rawInsert(
              'INSERT OR REPLACE INTO paths(file_id, local_path, rev) '
              'VALUES(?, ?, 1)',
              [f, p]);
        });
        legacy.kv.forEach((k, v) {
          batch.rawInsert('INSERT OR REPLACE INTO kv(k, v) VALUES(?, ?)', [k, v]);
        });
        await batch.commit(noResult: true);

        await _verifyCopy(txn, legacy, assetIds);

        await _kvPut(txn, _revKey, '1');
        await _kvPut(txn, RegistryKeys.migratedFlag, '1');
      });
    } on _AlreadyMigrated {
      await _cleanupPrefs(prefs, removalYield, simulateCrashAfterRemovals);
      return const MigrationResult(MigrationStatus.alreadyDone);
    } catch (e) {
      return MigrationResult(MigrationStatus.failed,
          detail: e is StateError ? e.message : 'copy failed: ${e.runtimeType}');
    }

    // 4. cleanup (data is already safe in the database).
    final result = MigrationResult(
      MigrationStatus.migrated,
      uploaded: legacy.uploaded.length,
      links: legacy.items.length,
      paths: legacy.paths.length,
      detail: legacy.reconstructedLinks == 0
          ? null
          : 'reconstructed=${legacy.reconstructedLinks}',
    );
    await _cleanupPrefs(prefs, removalYield, simulateCrashAfterRemovals);
    return result;
  }

  Future<void> _verifyCopy(
      Transaction txn, LegacyRegistry legacy, Set<String> assetIds) async {
    final linkRows =
        await txn.rawQuery('SELECT asset_id, file_id, uploaded FROM links');
    var upCount = 0;
    var fileCount = 0;
    for (final r in linkRows) {
      final a = r['asset_id'] as String;
      final f = r['file_id'] as String?;
      final up = (r['uploaded'] as int) != 0;
      if (up) upCount++;
      if (f != null) fileCount++;
      if (up != legacy.uploaded.contains(a) || f != legacy.items[a]) {
        throw StateError('verification failed: row mismatch');
      }
    }
    if (linkRows.length != assetIds.length ||
        upCount != legacy.uploaded.length ||
        fileCount != legacy.items.length) {
      throw StateError('verification failed: counts '
          'rows=${linkRows.length}/${assetIds.length} '
          'uploaded=$upCount/${legacy.uploaded.length} '
          'links=$fileCount/${legacy.items.length}');
    }
    final pathRows = await txn.rawQuery('SELECT file_id, local_path FROM paths');
    if (pathRows.length != legacy.paths.length) {
      throw StateError('verification failed: paths '
          '${pathRows.length}/${legacy.paths.length}');
    }
    for (final r in pathRows) {
      if (legacy.paths[r['file_id'] as String] != r['local_path']) {
        throw StateError('verification failed: path mismatch');
      }
    }
    for (final e in legacy.kv.entries) {
      if (await _kvGet(txn, e.key) != e.value) {
        throw StateError('verification failed: kv mismatch');
      }
    }
  }

  Future<void> _writeBackup(LegacyRegistry legacy, String path) async {
    final tmp = File('$path.tmp');
    final json = jsonEncode({
      'v': 1,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'entries': legacy.rawEntries,
    });
    await tmp.writeAsString(json, flush: true);
    final back = jsonDecode(await tmp.readAsString()) as Map<String, dynamic>;
    final entries = back['entries'] as Map<String, dynamic>;
    if (entries.length != legacy.rawEntries.length) {
      throw StateError('backup entry count mismatch');
    }
    await tmp.rename(path);
  }

  Future<void> _cleanupPrefs(
      SharedPreferences prefs, int removalYield, int? crashAfter) async {
    if (await readKv(RegistryKeys.cleanedFlag) == '1') return;
    try {
      final keys = prefs.getKeys().where(RegistryKeys.isLegacyKey).toList();
      var n = 0;
      for (final k in keys) {
        await prefs.remove(k);
        n++;
        if (crashAfter != null && n >= crashAfter) {
          throw StateError('simulated crash during prefs cleanup');
        }
        if (n % removalYield == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      await _kvPut(_db, RegistryKeys.cleanedFlag, '1');
    } catch (e) {
      if (crashAfter != null) rethrow;
      // Leftover keys are dead data; the next init retries the removal.
      debugPrint('TVDIAG: registry prefs cleanup incomplete (${e.runtimeType})');
    }
  }
}

// ---------------------------------------------------------------------------
// SharedPreferences fallback (legacy layout, untouched semantics)
// ---------------------------------------------------------------------------

class PrefsRegistryStorage implements RegistryStorage {
  PrefsRegistryStorage(this._prefs);
  final SharedPreferences _prefs;

  @override
  Future<void> close() async {}

  @override
  Future<RegistrySnapshot> load() async {
    // Lenient reads (`get` + type checks): a malformed value must not make
    // the whole registry unreadable, it is simply ignored.
    final snap = RegistrySnapshot(full: true);
    final items = <String, String>{};
    final uploaded = <String>{};
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith('bk_')) continue;
      final v = _prefs.get(key);
      if (key.startsWith(RegistryKeys.uploadedPrefix)) {
        if (v == true) {
          uploaded.add(key.substring(RegistryKeys.uploadedPrefix.length));
        }
      } else if (key.startsWith(RegistryKeys.fileItemPrefix)) {
        if (v is String) {
          items[key.substring(RegistryKeys.fileItemPrefix.length)] = v;
        }
      } else if (key.startsWith(RegistryKeys.linkPrefix)) {
        if (v is String) {
          snap.paths[key.substring(RegistryKeys.linkPrefix.length)] = v;
        }
      } else if (key == RegistryKeys.enabledAlbums) {
        if (v is List) {
          snap.kv[key] = jsonEncode(v.map((e) => '$e').toList());
        }
      } else if (key == RegistryKeys.allowMobileData) {
        if (v is bool) snap.kv[key] = LegacyRegistry.encodeBool(v);
      } else if (key == RegistryKeys.headlessRunMs) {
        if (v is int) snap.kv[key] = '$v';
      } else if (key == RegistryKeys.headlessStatus) {
        if (v is String) snap.kv[key] = v;
      }
    }
    final account = _prefs.get(RegistryKeys.account);
    if (account is String) snap.kv[RegistryKeys.account] = account;
    for (final a in {...uploaded, ...items.keys}) {
      snap.links.add(LinkRow(a, items[a], uploaded.contains(a)));
    }
    return snap;
  }

  @override
  Future<RegistrySnapshot> loadChanges() async {
    await _prefs.reload();
    return load();
  }

  @override
  Future<void> markUploaded(String assetId) async {
    await _prefs.setBool('${RegistryKeys.uploadedPrefix}$assetId', true);
  }

  @override
  Future<void> clearUploaded(String assetId) async {
    await _prefs.remove('${RegistryKeys.uploadedPrefix}$assetId');
  }

  @override
  Future<void> linkPath(String fileId, String path) async {
    await _prefs.setString('${RegistryKeys.linkPrefix}$fileId', path);
  }

  @override
  Future<void> linkFile(String assetId, String fileId) async {
    await _prefs.setString('${RegistryKeys.fileItemPrefix}$assetId', fileId);
    await _prefs.setString(
        '${RegistryKeys.assetForFileItemPrefix}$fileId', assetId);
  }

  @override
  Future<List<String>> unlinkFile(String fileId) async {
    await _prefs.remove('${RegistryKeys.linkPrefix}$fileId');
    final assetId =
        _prefs.getString('${RegistryKeys.assetForFileItemPrefix}$fileId');
    await _prefs.remove('${RegistryKeys.assetForFileItemPrefix}$fileId');
    if (assetId == null) return const [];
    await _prefs.remove('${RegistryKeys.fileItemPrefix}$assetId');
    await _prefs.remove('${RegistryKeys.uploadedPrefix}$assetId');
    return [assetId];
  }

  @override
  Future<void> commitUploads(List<UploadCommit> items) async {
    for (final it in items) {
      await markUploaded(it.assetId);
      await linkPath(it.fileItemId, it.path);
      await linkFile(it.assetId, it.fileItemId);
    }
  }

  /// Pending index rows of the fallback: one JSON list. Not a `bk_` key, so
  /// the legacy parse/cleanup never touches it.
  static const _pendingIndexKey = 'tv_pending_index';

  Future<List<TaggedPendingRow>> _readPending() async {
    try {
      await _prefs.reload();
    } catch (_) {}
    final raw = _prefs.getString(_pendingIndexKey);
    if (raw == null) return [];
    try {
      return [
        for (final e in (jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          (
            row: (
              assetId: e['a'] as String,
              fileItemId: e['f'] as String,
              itemJson: e['j'] as String,
              path: e['p'] as String,
            ),
            account: e['u'] as int?,
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _writePending(List<TaggedPendingRow> rows) => _prefs.setString(
      _pendingIndexKey,
      jsonEncode([
        for (final r in rows)
          {
            'a': r.row.assetId,
            'f': r.row.fileItemId,
            'j': r.row.itemJson,
            'p': r.row.path,
            if (r.account != null) 'u': r.account,
          },
      ]));

  @override
  Future<void> addPendingIndex(PendingIndexRow row, {int? account}) async {
    final rows = await _readPending();
    rows.removeWhere((r) => r.row.fileItemId == row.fileItemId);
    rows.add((row: row, account: account));
    await _writePending(rows);
  }

  @override
  Future<List<PendingIndexRow>> pendingIndex() async =>
      [for (final r in await _readPending()) r.row];

  @override
  Future<List<TaggedPendingRow>> pendingIndexTagged() => _readPending();

  @override
  Future<void> tagUntaggedPendingIndex(int account) async {
    final rows = await _readPending();
    if (rows.every((r) => r.account != null)) return;
    await _writePending([
      for (final r in rows) (row: r.row, account: r.account ?? account),
    ]);
  }

  @override
  Future<void> clearLinks() async {
    for (final key in _prefs.getKeys().toList()) {
      if (key.startsWith(RegistryKeys.uploadedPrefix) ||
          key.startsWith(RegistryKeys.linkPrefix) ||
          key.startsWith(RegistryKeys.fileItemPrefix) ||
          key.startsWith(RegistryKeys.assetForFileItemPrefix)) {
        await _prefs.remove(key);
      }
    }
  }

  @override
  Future<void> removePendingIndex(List<String> fileItemIds) async {
    if (fileItemIds.isEmpty) return;
    final ids = fileItemIds.toSet();
    final rows = await _readPending();
    rows.removeWhere((r) => ids.contains(r.row.fileItemId));
    await _writePending(rows);
  }

  @override
  Future<void> setKvMany(Map<String, String> entries) async {
    for (final e in entries.entries) {
      switch (e.key) {
        case RegistryKeys.enabledAlbums:
          final list = (jsonDecode(e.value) as List).map((x) => '$x').toList();
          await _prefs.setStringList(e.key, list);
        case RegistryKeys.allowMobileData:
          await _prefs.setBool(e.key, e.value == '1');
        case RegistryKeys.headlessRunMs:
          await _prefs.setInt(e.key, int.tryParse(e.value) ?? 0);
        default:
          await _prefs.setString(e.key, e.value);
      }
    }
  }
}
