import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/file_index.dart';
import '../../models/file_item.dart';
import '../backup/backup_registry.dart';
import '../telegram/client.dart';
import 'index_cache.dart';
import 'index_remote.dart';

/// Reads and writes the vault index to the user's Telegram "Saved Messages".
///
/// The index is stored as an uploaded JSON document (`televault_index.json`)
/// whose message caption is [indexMarker], so it can be found again on any
/// device. Storing it as a document — rather than a plain text message —
/// removes the 4096-character cap a text message would impose.
///
/// Backward compatible: an older text-message index (caption starts with the
/// marker, no media) is read and then rewritten as a document on the next
/// save, and the stale text message is deleted.
///
/// This class is the UI-isolate facade. The Telegram I/O lives in
/// `index_remote.dart` and runs on the download worker isolate; JSON decode,
/// encode, merge and rebase run through `Isolate.run`. Writes are guarded:
///
/// - every write is preceded by a local backup of what is stored remotely
///   (`index_backups/`, see [IndexCache]); no backup, no write;
/// - a write only replaces the document this writer last read ([documentId]);
///   when another writer (the headless WorkManager engine, another device)
///   changed it meanwhile, the changes are rebased onto the remote copy with
///   [FileIndex.rebase] and written once more;
/// - every write is read back and checked before it counts as saved.
///
/// Calls must not overlap (the app's [IndexNotifier] chains them; the
/// headless engine runs them in sequence).
class IndexService {
  IndexService._(this._remote, this._cache, this._accountKey);

  static final IndexService instance =
      IndexService._(const WorkerIndexRemote(), IndexCache(), _currentAccountKey);

  /// A service with its own remote, cache and account source (tests).
  @visibleForTesting
  IndexService.forTesting({
    required IndexRemote remote,
    required IndexCache cache,
    int? Function()? accountKey,
  }) : this._(remote, cache, accountKey ?? _noAccountKey);

  static int? _noAccountKey() => null;

  /// The `AuthorizationKey.id` of this isolate's Telegram session, or null
  /// when not connected (offline cold start). Ties the cache and the
  /// synced state to an account.
  static int? _currentAccountKey() {
    try {
      final s = TelegramService.instance;
      return s.isConnected ? s.client.authorizationKey.id : null;
    } catch (_) {
      return null;
    }
  }

  static const String _persistedMsgIdKey = 'tv_index_msg_id';
  static const String _persistedLegacyKey = 'tv_index_msg_legacy';

  final IndexRemote _remote;
  final IndexCache _cache;
  final int? Function() _accountKey;

  /// Message id of the current index message, once known.
  int? _messageId;

  /// True when [_messageId] points at a legacy text message that must be
  /// replaced (not edited) by a document on the next save.
  bool _legacy = false;

  /// Document id of the index as this writer last read or wrote it.
  int? _documentId;

  /// The index as last known remote (what the caller's state derives from)
  /// and its exact bytes (backed up before the next write).
  FileIndex? _base;
  Uint8List? _baseBytes;

  /// True once a [load] or [save] established [_messageId]/[_documentId]/
  /// [_base] from the remote in this isolate, for [_syncedAccount].
  bool _synced = false;
  int? _syncedAccount;

  /// The last index known to be stored remotely, with its bytes: the device
  /// cache published by [readCache], then the result of every load/save.
  /// A load whose document id matches is served from here (no download, no
  /// decode).
  CachedIndex? _cached;

  int? get messageId => _messageId;

  /// True once a [load] or [save] in this isolate succeeded against Telegram:
  /// only then can the index be trusted to tell what is already in the vault.
  bool get synced => _synced;

  /// Document id of the index as last read or written by this isolate.
  int? get documentId => _documentId;

  /// True after [load] reads a legacy text-message index, signalling the caller
  /// to persist once so it gets rewritten as a document.
  bool get needsMigration => _legacy;

  /// Remembers [_messageId] on-device so future [load] calls can jump
  /// straight to it instead of depending on it still being within the most
  /// recent history window.
  Future<void> _persistMessageId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = _messageId;
    if (id == null) {
      await prefs.remove(_persistedMsgIdKey);
      await prefs.remove(_persistedLegacyKey);
    } else {
      await prefs.setInt(_persistedMsgIdKey, id);
      await prefs.setBool(_persistedLegacyKey, _legacy);
    }
  }

  /// Runs a remote operation, reporting its failures as [IndexException].
  Future<R> _guard<R>(Future<R> Function() op) async {
    try {
      return await op();
    } on IndexRemoteException catch (e) {
      throw IndexException(e.message);
    } on FloodWaitException catch (e) {
      throw IndexException('Telegram asked to wait: FLOOD_WAIT_${e.seconds}',
          floodWaitSeconds: e.seconds);
    }
  }

  /// The index as cached on this device by the last load/save, or null
  /// (none, unreadable, or written by another account's session). Decoded
  /// off the UI isolate. Remembered so the next [load] skips downloading and
  /// decoding it when the remote still holds the same document.
  Future<FileIndex?> readCache() async {
    final c = await _cache.read();
    if (c == null) return null;
    final account = _accountKey();
    if (account != null && c.account != account) return null;
    _cached = c;
    return c.index;
  }

  /// Records what the remote holds now, and that this isolate is in sync.
  void _adopt({
    required int? messageId,
    required int? documentId,
    required bool legacy,
    required FileIndex base,
    required Uint8List? bytes,
  }) {
    _messageId = messageId;
    _documentId = documentId;
    _legacy = legacy;
    _base = base;
    _baseBytes = bytes;
    _synced = true;
    _syncedAccount = _accountKey();
    if (messageId != null && bytes != null) {
      _cached = CachedIndex(
        index: base,
        bytes: bytes,
        messageId: messageId,
        documentId: documentId,
        legacy: legacy,
        account: _syncedAccount,
      );
    }
  }

  /// Persists [_cached] to the device. A failure only costs the next cold
  /// start its early publish, so it is logged (no content) and swallowed.
  Future<void> _writeCacheFile() async {
    final c = _cached;
    if (c == null) return;
    try {
      await _cache.write(
        c.bytes,
        messageId: c.messageId,
        documentId: c.documentId,
        legacy: c.legacy,
        account: c.account,
      );
    } catch (e) {
      debugPrint('TVDIAG: index cache write failed: ${e.runtimeType}');
    }
  }

  /// Loads the index. Returns an empty index if none exists yet.
  ///
  /// The index is located by searching Saved Messages for its marker caption
  /// (see `remoteLoad`). A search can surface more than one snapshot (earlier
  /// forks that were never merged back). Those are unioned into one index,
  /// saved over the primary message, and the leftover snapshot messages are
  /// deleted — so the vault heals itself instead of needing a manual
  /// recovery. If neither the search nor the remembered id yields an index,
  /// the older lookup (recent history, then a deep scan) runs.
  Future<FileIndex> load() async {
    final prefs = await SharedPreferences.getInstance();
    final persistedId = prefs.getInt(_persistedMsgIdKey);
    final cached = _cached;

    final snap = await _guard(() => _remote.load(RemoteLoadArgs(
          persistedId: persistedId,
          cachedDocumentId: cached == null || cached.legacy ? null : cached.documentId,
        )));
    if (snap.clearPersisted) {
      await prefs.remove(_persistedMsgIdKey);
      await prefs.remove(_persistedLegacyKey);
    }

    switch (snap.kind) {
      case RemoteIndexKind.documents:
        return _loadFromDocuments(snap.docs, persistedId);
      case RemoteIndexKind.single:
        return _loadSingle(snap.docs.single);
      case RemoteIndexKind.legacy:
        return _loadLegacy(snap.legacyMessageId!, snap.legacyPayload ?? '');
      case RemoteIndexKind.none:
        _adopt(messageId: null, documentId: null, legacy: false, base: FileIndex.empty(), bytes: null);
        return FileIndex.empty();
    }
  }

  /// A document index found by the fallback lookup.
  Future<FileIndex> _loadSingle(RemoteIndexDoc doc) async {
    _messageId = doc.messageId;
    _legacy = false;
    await _persistMessageId();
    if (doc.error != null) throw IndexException(doc.error!);
    final bytes = doc.bytes!.materialize().asUint8List();
    final FileIndex index;
    try {
      index = await _decodeIndex(bytes);
    } catch (e) {
      throw IndexException('Index document is corrupt: $e');
    }
    _adopt(
      messageId: doc.messageId,
      documentId: doc.documentId,
      legacy: false,
      base: index,
      bytes: bytes,
    );
    await _writeCacheFile();
    return index;
  }

  /// Legacy format: JSON inline after the marker in a text message.
  Future<FileIndex> _loadLegacy(int messageId, String payload) async {
    _messageId = messageId;
    _legacy = true;
    await _persistMessageId();
    var index = FileIndex.empty();
    if (payload.isNotEmpty) {
      try {
        index = await _decodeIndex(Uint8List.fromList(utf8.encode(payload)));
      } catch (e) {
        throw IndexException('Legacy index message is corrupt: $e');
      }
    }
    _adopt(
      messageId: messageId,
      documentId: null,
      legacy: true,
      base: index,
      bytes: Uint8List.fromList(utf8.encode(payload)),
    );
    await _writeCacheFile();
    return index;
  }

  /// Decodes [docs] (document-format index messages, newest first), merges
  /// them if there is more than one, and — when a merge happened — writes the
  /// union back over the primary message and deletes the now-redundant
  /// snapshot messages.
  Future<FileIndex> _loadFromDocuments(List<RemoteIndexDoc> docs, int? persistedId) async {
    final decoded = <({RemoteIndexDoc doc, FileIndex index, Uint8List bytes})>[];
    Object? firstError;
    for (final d in docs) {
      try {
        final c = _cached;
        if (d.cached) {
          if (c == null || c.documentId != d.documentId) {
            throw IndexException('Cached index is no longer available.');
          }
          decoded.add((doc: d, index: c.index, bytes: c.bytes));
          continue;
        }
        if (d.error != null) throw IndexException(d.error!);
        final bytes = d.bytes!.materialize().asUint8List();
        // Off the main isolate: a multi-MB index decoded synchronously on the
        // UI thread is a visible hitch at every cold start.
        decoded.add((doc: d, index: await _decodeIndex(bytes), bytes: bytes));
      } catch (e) {
        firstError ??= e;
      }
    }
    if (decoded.isEmpty) {
      throw IndexException('Index document is corrupt: $firstError');
    }
    // The live lineage failing to download (a transient network error) must
    // not silently hand the app an older fork as if it were current.
    if (persistedId != null &&
        docs.any((d) => d.messageId == persistedId) &&
        decoded.every((d) => d.doc.messageId != persistedId)) {
      throw IndexException('Could not read the current index: $firstError');
    }

    // The remembered message is the live lineage; otherwise the newest one.
    final primary = decoded.firstWhere(
      (d) => d.doc.messageId == persistedId,
      orElse: () => decoded.first,
    );
    _adopt(
      messageId: primary.doc.messageId,
      documentId: primary.doc.documentId,
      legacy: false,
      base: primary.index,
      bytes: primary.bytes,
    );
    await _persistMessageId();
    if (!primary.doc.cached) await _writeCacheFile();
    if (decoded.length == 1) return primary.index;

    // Oldest first with the primary last, so for any id present in several
    // snapshots the primary's version (e.g. archived flag) wins.
    final others = decoded.where((d) => d.doc.messageId != primary.doc.messageId).toList().reversed;
    var merged = await _mergeIndexes([for (final d in others) d.index, primary.index]);
    merged = await _dropDeletedFiles(merged, primary.index);

    // A snapshot that couldn't be read is never consolidated away: write
    // nothing and delete nothing, just serve the union (the next regular save
    // persists it).
    if (decoded.length < docs.length) return merged;

    try {
      final written = await save(merged);
      final stale = [
        for (final d in decoded)
          if (d.doc.messageId != _messageId) d.doc.messageId,
      ];
      if (stale.isNotEmpty) await _remote.deleteMessages(stale);
      return written;
    } catch (_) {
      // Consolidation is best-effort: the merged index is still returned and
      // gets written by the next regular save; nothing is deleted unless the
      // merged copy was saved (and verified) first.
    }
    return merged;
  }

  /// Merging older snapshots can resurrect files the live lineage deleted
  /// (their Telegram messages are already gone, so they'd show as broken
  /// tiles). For files that exist only in an older snapshot, checks their
  /// messages still exist and drops the ones that don't, along with their
  /// album memberships. Any lookup error keeps the entry — never drops on doubt.
  Future<FileIndex> _dropDeletedFiles(FileIndex merged, FileIndex primary) async {
    final primaryIds = {for (final f in primary.files) f.id};
    final extra = merged.files.where((f) => !primaryIds.contains(f.id)).toList();
    if (extra.isEmpty) return merged;

    final messageIds = <int>{
      for (final f in extra)
        for (final part in f.parts) part.messageId,
    }.toList();
    final List<int>? found;
    try {
      found = await _remote.existingMessageIds(messageIds);
    } catch (_) {
      return merged;
    }
    if (found == null) return merged;
    final existing = found.toSet();

    final gone = {
      for (final f in extra)
        if (!f.parts.every((p) => existing.contains(p.messageId))) f.id,
    };
    if (gone.isEmpty) return merged;
    return merged.copyWith(
      files: merged.files.where((f) => !gone.contains(f.id)).toList(),
      albums: [
        for (final a in merged.albums)
          a.copyWith(fileIds: a.fileIds.where((id) => !gone.contains(id)).toList()),
      ],
    );
  }

  /// Persists [local] and returns the index actually written, which the
  /// caller MUST adopt as its new state: when another writer changed the
  /// remote index since this isolate last read it, [local]'s changes are
  /// rebased onto the remote copy ([FileIndex.rebase]), so the result can
  /// hold more than [local]. Keeping [local] instead would make the next save
  /// read the other writer's additions as deletions.
  ///
  /// Ids of [local]'s new files dropped by the rebase as duplicates of a
  /// remote file (same name and size) go to [onDroppedDuplicates].
  ///
  /// Order: (1) local backup of the current remote bytes (no backup, no
  /// write); (2) conditional write + read-back verification
  /// ([remoteWrite]); (3) on a conflict, backup of the remote bytes, rebase,
  /// one more conditional write. A second conflict, or any failure, throws
  /// [IndexException] and leaves the remote untouched by this call (or holding
  /// an unverified copy, which the next save treats as a conflict); the bytes
  /// that could not be written are kept as an `-unsaved` backup.
  Future<FileIndex> save(
    FileIndex local, {
    void Function(List<String> droppedIds)? onDroppedDuplicates,
  }) async {
    final account = _accountKey();
    if (_synced && _syncedAccount != null && account != null && account != _syncedAccount) {
      throw IndexException('The Telegram account changed; reload the index before saving.');
    }

    final dropped = <String>[];
    var toWrite = local;
    Uint8List bytes;
    if (!_synced) {
      // No remote state in this isolate yet (the startup load failed, e.g.
      // offline; the caller's state came from the device cache or is empty).
      // Never write blind: read the remote first, then rebase [local] onto
      // it from what it was derived from.
      final derivedFrom = _cached?.index ?? FileIndex.empty();
      final remoteNow = await load();
      final r = await _rebaseIndex(base: derivedFrom, local: local, remote: remoteNow);
      toWrite = r.index;
      dropped.addAll(r.dropped);
      bytes = r.bytes;
    } else {
      bytes = await _encodeIndex(local);
    }

    try {
      await _backupRemote();
      var result = await _guard(() => _remote.write(RemoteWriteArgs(
            messageId: _messageId,
            expectedDocumentId: _documentId,
            legacy: _legacy,
            bytes: TransferableTypedData.fromList([bytes]),
          )));

      if (result.conflict) {
        final remoteBytes = result.remoteBytes!.materialize().asUint8List();
        await _backup(remoteBytes);
        final r = await _rebaseIndexBytes(
          base: _base ?? FileIndex.empty(),
          local: toWrite,
          remoteBytes: remoteBytes,
        );
        toWrite = r.index;
        dropped.addAll(r.dropped);
        bytes = r.bytes;
        final retryMessageId = result.messageId;
        final retryExpected = result.remoteDocumentId;
        result = await _guard(() => _remote.write(RemoteWriteArgs(
              messageId: retryMessageId,
              expectedDocumentId: retryExpected,
              legacy: false,
              bytes: TransferableTypedData.fromList([bytes]),
            )));
        if (result.conflict) {
          throw IndexException(
            'The index kept changing on Telegram while saving; nothing was overwritten. Try again.',
          );
        }
      }

      _adopt(
        messageId: result.messageId,
        documentId: result.documentId,
        legacy: false,
        base: toWrite,
        bytes: bytes,
      );
      await _persistMessageId();
      await _writeCacheFile();
      if (dropped.isNotEmpty) onDroppedDuplicates?.call(List.unmodifiable(dropped));
      return toWrite;
    } catch (e) {
      // Keep what could not be written, so nothing is lost locally.
      try {
        await _cache.backup(bytes, label: 'unsaved');
      } catch (_) {}
      if (e is IndexException) rethrow;
      throw IndexException('Failed to write index: $e');
    }
  }

  /// Backs up what the remote holds now, before it is overwritten. Throws
  /// when there is something to back up and the backup fails.
  Future<void> _backupRemote() async {
    final bytes = _baseBytes ?? _cached?.bytes;
    if (bytes == null) {
      if (_messageId != null) {
        throw IndexException('No local copy of the current index to back up; not writing.');
      }
      return; // No index anywhere yet: nothing to lose.
    }
    await _backup(bytes);
  }

  Future<void> _backup(Uint8List bytes) async {
    try {
      await _cache.backup(bytes);
    } catch (e) {
      throw IndexException('Could not write the local index backup; not writing: $e');
    }
  }

  /// Cheap check whether the remote index document differs from the one this
  /// isolate last read or wrote. Null when unknown (not loaded yet, legacy,
  /// or the lookup failed).
  Future<bool?> remoteChanged() async {
    final id = _messageId;
    final doc = _documentId;
    if (!_synced || id == null || _legacy || doc == null) return null;
    try {
      final current = await _remote.documentIdOf(id);
      if (current == null) return null;
      return current != doc;
    } catch (_) {
      return null;
    }
  }

  /// Permanently deletes the given files' messages (all parts) from Telegram,
  /// freeing the storage, and clears any backup-registry links pointing at
  /// them. The index update is the caller's responsibility.
  ///
  /// Throws (without touching the index) if any chunk's delete actually
  /// failed server-side — the caller's mutation must not proceed to drop
  /// items from the index that are still sitting in Telegram, un-deletable
  /// from the UI afterwards and silently consuming storage.
  Future<void> deleteFromTelegram(List<FileItem> items) async {
    final ids = <int>[
      for (final item in items)
        for (final part in item.parts) part.messageId,
    ];
    if (ids.isNotEmpty) {
      // deleteMessages caps at ~100 ids per call; chunk to be safe.
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
        final result = await TelegramService.instance.call(
          (c) => c.messages.deleteMessages(revoke: true, id: chunk),
        );
        if (result.error != null) {
          throw IndexException('Failed to delete messages: ${result.error!.errorMessage}');
        }
      }
    }
    for (final item in items) {
      await BackupRegistry.instance.unlinkFileItem(item.id);
    }
  }

  /// Scans the *entire* Saved Messages history for every message tagged as
  /// an index snapshot, and returns each decoded snapshot oldest-first — the
  /// recovery/diagnostic tool for indexes orphaned by an older app version
  /// that started a fresh index when it could not find the existing one.
  Future<List<FileIndex>> findAllIndexSnapshots({int maxMessages = 20000}) async {
    final raw = await _guard(() => _remote.scanAllSnapshots(maxMessages));
    final snapshots = <FileIndex>[];
    for (final b in raw) {
      try {
        snapshots.add(await _decodeIndex(b.materialize().asUint8List()));
      } catch (_) {
        // Corrupt/partial snapshot — skip it.
      }
    }
    return snapshots.reversed.toList(); // oldest first
  }
}

// Off-UI-isolate helpers. Top-level so the closures handed to Isolate.run
// capture only their arguments.

Future<FileIndex> _decodeIndex(Uint8List bytes) =>
    Isolate.run(() => FileIndex.decode(utf8.decode(bytes)));

Future<Uint8List> _encodeIndex(FileIndex index) =>
    Isolate.run(() => utf8.encode(index.encode()));

Future<FileIndex> _mergeIndexes(List<FileIndex> snapshots) =>
    Isolate.run(() => FileIndex.merge(snapshots));

typedef _Rebased = ({FileIndex index, List<String> dropped, Uint8List bytes});

Future<_Rebased> _rebaseIndex({
  required FileIndex base,
  required FileIndex local,
  required FileIndex remote,
}) =>
    Isolate.run(() {
      final r = FileIndex.rebase(base: base, local: local, remote: remote);
      return (index: r.index, dropped: r.droppedDuplicates, bytes: utf8.encode(r.index.encode()));
    });

Future<_Rebased> _rebaseIndexBytes({
  required FileIndex base,
  required FileIndex local,
  required Uint8List remoteBytes,
}) =>
    Isolate.run(() {
      final remote = FileIndex.decode(utf8.decode(remoteBytes));
      final r = FileIndex.rebase(base: base, local: local, remote: remote);
      return (index: r.index, dropped: r.droppedDuplicates, bytes: utf8.encode(r.index.encode()));
    });

class IndexException implements Exception {
  final String message;

  /// Set when the failure is a FLOOD_WAIT that was too long to wait out (see
  /// [FloodWaitException]): the seconds Telegram asked for.
  final int? floodWaitSeconds;

  IndexException(this.message, {int? floodWaitSeconds})
      : floodWaitSeconds = floodWaitSeconds ?? floodWaitSecondsOf(message);
  @override
  String toString() => 'IndexException: $message';
}
