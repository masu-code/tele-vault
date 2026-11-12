import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:t/t.dart' as t;

import '../download/download_plan.dart';
import '../download/download_service.dart' show DownloadException;
import '../download/download_worker.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import '../upload/upload_plan.dart';

/// The Telegram I/O of the vault index, split out of `IndexService` so it can
/// run on the download worker isolate (through [DownloadWorker.run]) instead
/// of the UI isolate: the MTProto layer AES-decrypts every byte of the index
/// document synchronously on whichever isolate owns the connection.
///
/// Everything here exchanges raw bytes (as [TransferableTypedData]) and ids
/// only. JSON decoding, merging and rebasing stay with the caller
/// (`IndexService`), which runs them through `Isolate.run`.

/// Caption every index message starts with.
const String indexMarker = 'TELEVAULT_INDEX_V1';

/// File name of the index document.
const String indexFileName = 'televault_index.json';

/// How far back the last-resort history scan of [remoteLoad] looks when
/// neither the search nor a remembered message id found the index.
const int _deepScanLimit = 5000;

/// Thrown by the remote functions; re-thrown by `IndexService` as its own
/// `IndexException` with the same message.
class IndexRemoteException implements Exception {
  final String message;
  IndexRemoteException(this.message);
  @override
  String toString() => 'IndexException: $message';
}

// ---------------------------------------------------------------------------
// Messages exchanged with the worker (all fields sendable between isolates).
// ---------------------------------------------------------------------------

class RemoteLoadArgs {
  /// Index message id remembered on this device, if any.
  final int? persistedId;

  /// Document id of the locally cached index. A snapshot with this document
  /// id is not downloaded (its bytes are already on the device).
  final int? cachedDocumentId;

  const RemoteLoadArgs({this.persistedId, this.cachedDocumentId});
}

/// One document-format index message found by [remoteLoad].
class RemoteIndexDoc {
  final int messageId;
  final int documentId;
  final int size;

  /// True when [documentId] equals [RemoteLoadArgs.cachedDocumentId]: not
  /// downloaded, the caller uses its cached copy.
  final bool cached;

  /// The document's bytes, unless [cached] or [error].
  final TransferableTypedData? bytes;

  /// Why the download failed, if it did.
  final String? error;

  const RemoteIndexDoc({
    required this.messageId,
    required this.documentId,
    required this.size,
    this.cached = false,
    this.bytes,
    this.error,
  });
}

enum RemoteIndexKind {
  /// Found by marker search and/or the remembered id: one or more snapshots
  /// in [RemoteIndexSnapshot.docs] (newest first), to be merged.
  documents,

  /// Found by the fallback lookup (remembered id, then history scans): a
  /// single document in [RemoteIndexSnapshot.docs].
  single,

  /// Found by the fallback lookup: a legacy text-message index.
  legacy,

  /// No index anywhere.
  none,
}

/// Result of [remoteLoad].
class RemoteIndexSnapshot {
  final RemoteIndexKind kind;
  final List<RemoteIndexDoc> docs;

  /// [RemoteIndexKind.legacy] only.
  final int? legacyMessageId;
  final String? legacyPayload;

  /// The remembered id turned out stale (the fallback lookup ran and the
  /// remembered message is gone or is not an index): forget it.
  final bool clearPersisted;

  const RemoteIndexSnapshot({
    required this.kind,
    this.docs = const [],
    this.legacyMessageId,
    this.legacyPayload,
    this.clearPersisted = false,
  });
}

class RemoteWriteArgs {
  /// Index message to edit. Null (or [legacy]) creates a new index message.
  final int? messageId;

  /// The document id the caller's base was read from. The write is refused
  /// (a conflict is returned) when the message holds another document.
  final int? expectedDocumentId;

  /// [messageId] is a legacy text message: create a document message, then
  /// delete it.
  final bool legacy;

  final TransferableTypedData bytes;

  const RemoteWriteArgs({
    required this.messageId,
    required this.expectedDocumentId,
    required this.legacy,
    required this.bytes,
  });
}

/// Result of [remoteWrite]: either written and verified ([conflict] false,
/// [messageId] + [documentId] set), or a conflict (nothing of ours is in
/// effect; [remoteBytes]/[remoteDocumentId] hold what is stored now).
class RemoteWriteResult {
  final bool conflict;
  final int? messageId;
  final int? documentId;
  final TransferableTypedData? remoteBytes;
  final int? remoteDocumentId;

  const RemoteWriteResult.written({required int this.messageId, required int this.documentId})
      : conflict = false,
        remoteBytes = null,
        remoteDocumentId = null;

  const RemoteWriteResult.conflict({
    required this.messageId,
    required TransferableTypedData this.remoteBytes,
    required int this.remoteDocumentId,
  })  : conflict = true,
        documentId = null;
}

// ---------------------------------------------------------------------------
// Transport seam (tests replace it with an in-memory fake).
// ---------------------------------------------------------------------------

/// The index's remote operations. [WorkerIndexRemote] runs them through
/// [DownloadWorker.run]; tests provide a fake.
abstract class IndexRemote {
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args);
  Future<RemoteWriteResult> write(RemoteWriteArgs args);

  /// Which of [messageIds] still exist; null when the lookup failed.
  Future<List<int>?> existingMessageIds(List<int> messageIds);

  /// Best-effort delete of stale snapshot messages (revoke: false).
  Future<void> deleteMessages(List<int> messageIds);

  /// Document id currently held by index message [messageId]; 0 when the
  /// message is gone or holds no document; null when the lookup failed.
  Future<int?> documentIdOf(int messageId);

  /// Every index document in history (newest first), up to [maxMessages]
  /// scanned messages. Unreadable ones are skipped.
  Future<List<TransferableTypedData>> scanAllSnapshots(int maxMessages);
}

class WorkerIndexRemote implements IndexRemote {
  const WorkerIndexRemote();

  /// Every remote function reports progress per RPC, so this only trips on a
  /// genuinely stalled call (one RPC can take ~2 min with reconnects, and a
  /// flood wait on the edit can be longer).
  static const Duration _timeout = Duration(minutes: 5);

  Future<R> _run<A, R>(Future<R> Function(A) fn, A arg) async {
    try {
      return await DownloadWorker.run<A, R>(fn, arg, inactivityTimeout: _timeout);
    } on DownloadException catch (e) {
      // Errors cross the isolate boundary as text; keep the index wording.
      const prefix = 'IndexException: ';
      final m = e.message;
      // A FLOOD_WAIT that TelegramService.call gave up on stays typed, the
      // same as when the remote functions run inline (headless, tests).
      final flood = FloodWaitException.tryParse(m);
      if (flood != null) throw flood;
      throw IndexRemoteException(m.startsWith(prefix) ? m.substring(prefix.length) : m);
    }
  }

  @override
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args) => _run(remoteLoad, args);

  @override
  Future<RemoteWriteResult> write(RemoteWriteArgs args) => _run(remoteWrite, args);

  @override
  Future<List<int>?> existingMessageIds(List<int> messageIds) =>
      _run(remoteExistingMessageIds, messageIds);

  @override
  Future<void> deleteMessages(List<int> messageIds) => _run(remoteDeleteMessages, messageIds);

  @override
  Future<int?> documentIdOf(int messageId) => _run(remoteDocumentIdOf, messageId);

  @override
  Future<List<TransferableTypedData>> scanAllSnapshots(int maxMessages) =>
      _run(remoteScanAllSnapshots, maxMessages);
}

// ---------------------------------------------------------------------------
// Top-level functions (run on the worker isolate, or inline when the worker
// is disabled: headless engine, desktop, tests).
// ---------------------------------------------------------------------------

/// The read-only RPCs the index lookup ([remoteLoad]) makes. Tests replace
/// [indexLookupRpc] with a fake.
@visibleForTesting
class IndexLookupRpc {
  const IndexLookupRpc();

  /// `messages.search` of Saved Messages for the index marker.
  Future<t.Result<t.MessagesMessagesBase>> search() =>
      TelegramService.instance.call((c) => c.messages.search(
            peer: const t.InputPeerSelf(),
            q: indexMarker,
            filter: const t.InputMessagesFilterDocument(),
            minDate: DateTime.fromMillisecondsSinceEpoch(0),
            maxDate: DateTime.fromMillisecondsSinceEpoch(0),
            offsetId: 0,
            addOffset: 0,
            limit: 100,
            maxId: 0,
            minId: 0,
            hash: 0,
          ));

  /// `messages.getMessages` of one Saved Messages id.
  Future<t.Result<t.MessagesMessagesBase>> getMessage(int id) =>
      TelegramService.instance.call((c) => c.messages.getMessages(
            id: [t.InputMessageID(id: id)],
          ));

  /// One page (100) of Saved Messages history, older than [offsetId]
  /// (0 = newest).
  Future<t.Result<t.MessagesMessagesBase>> history(int offsetId) =>
      TelegramService.instance.call((c) => c.messages.getHistory(
            peer: const t.InputPeerSelf(),
            offsetId: offsetId,
            offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
            addOffset: 0,
            limit: 100,
            maxId: 0,
            minId: 0,
            hash: 0,
          ));
}

@visibleForTesting
IndexLookupRpc indexLookupRpc = const IndexLookupRpc();

bool _isIndexDocument(t.MessageBase m) =>
    m is t.Message &&
    m.message.startsWith(indexMarker) &&
    m.media is t.MessageMediaDocument &&
    (m.media as t.MessageMediaDocument).document is t.Document;

t.Document _documentOf(t.Message m) =>
    (m.media as t.MessageMediaDocument).document as t.Document;

/// Locates the index (search by marker, plus the remembered id; fallback:
/// remembered id, recent history, deep history scan) and downloads every
/// document-format snapshot except the one already cached.
///
/// The index is located by **searching Saved Messages for its marker
/// caption**, not by walking recent history: every uploaded file posts its
/// own message there, so after a reinstall (which wipes the remembered
/// message id) the index sits thousands of messages back, and a recent-
/// history scan used to miss it — the app then loaded an empty vault, and
/// the next save started a brand-new index, orphaning every file uploaded
/// before (old backups vanished from Gallery with no error).
Future<RemoteIndexSnapshot> remoteLoad(RemoteLoadArgs args) async {
  final persistedId = args.persistedId;

  final docs = <t.Message>[];
  final found = await _searchIndexMessages();
  for (final m in found ?? const <t.Message>[]) {
    if (docs.every((d) => d.id != m.id)) docs.add(m);
  }

  // The remembered id is checked even when the search found something:
  // search indexing can lag a just-written message, and this keeps the
  // newest lineage from being missed.
  if (persistedId != null && docs.every((d) => d.id != persistedId)) {
    final result = await indexLookupRpc.getMessage(persistedId);
    WorkerProgress.report(0);
    if (result.error == null) {
      for (final msg in extractMessages(result.result)) {
        if (_isIndexDocument(msg)) docs.add(msg as t.Message);
      }
    }
  }

  if (docs.isEmpty) return _loadByRecentScan(persistedId, searchOk: found != null);

  docs.sort((a, b) => b.id.compareTo(a.id)); // newest first
  final out = <RemoteIndexDoc>[];
  for (final m in docs) {
    out.add(await _fetchDoc(m, args.cachedDocumentId));
  }
  return RemoteIndexSnapshot(kind: RemoteIndexKind.documents, docs: out);
}

Future<RemoteIndexDoc> _fetchDoc(t.Message m, int? cachedDocumentId) async {
  final doc = _documentOf(m);
  if (doc.id == cachedDocumentId) {
    return RemoteIndexDoc(messageId: m.id, documentId: doc.id, size: doc.size, cached: true);
  }
  try {
    final bytes = await downloadIndexDocument(doc);
    return RemoteIndexDoc(
      messageId: m.id,
      documentId: doc.id,
      size: doc.size,
      bytes: TransferableTypedData.fromList([bytes]),
    );
  } catch (e) {
    return RemoteIndexDoc(
      messageId: m.id,
      documentId: doc.id,
      size: doc.size,
      error: e is IndexRemoteException ? e.message : e.toString(),
    );
  }
}

/// Every document-format index message Saved Messages has, found by its
/// marker caption. Null (never throws) if the search itself fails (RPC error,
/// a flood wait that outlasts the retry, transport) — the caller then falls
/// back to the older lookup paths, and must not read their coming up empty
/// as "no index" unless they read all of history.
Future<List<t.Message>?> _searchIndexMessages() async {
  try {
    final result = await withFloodWaitRetry(indexLookupRpc.search, maxRetries: 1);
    WorkerProgress.report(0);
    if (result.error != null) return null;
    return extractMessages(result.result)
        .where(_isIndexDocument)
        .cast<t.Message>()
        .toList();
  } catch (_) {
    return null;
  }
}

/// Older lookup, kept as the fallback for [remoteLoad]: the remembered
/// message id first, then a scan of recent history, then a deeper scan.
///
/// The real lookup is by remembered message id via a direct, O(1)
/// `messages.getMessages` call. Only a fresh install (nothing persisted yet)
/// or a persisted id that no longer resolves falls back to scanning recent
/// history, then up to [_deepScanLimit] messages back.
///
/// "No index" ([RemoteIndexKind.none], which lets the next save create a
/// brand-new index message) is only concluded when the marker search
/// succeeded ([searchOk]) or the scan read all of history. A failed search
/// plus a scan that stopped at the cap or on an error throws instead: the
/// index may well sit further back, and forking it means an empty vault and
/// a full re-upload.
Future<RemoteIndexSnapshot> _loadByRecentScan(int? persistedId, {required bool searchOk}) async {
  var clearPersisted = false;
  if (persistedId != null) {
    final result = await indexLookupRpc.getMessage(persistedId);
    WorkerProgress.report(0);
    if (result.error == null) {
      for (final msg in extractMessages(result.result)) {
        if (msg is t.Message && msg.message.startsWith(indexMarker)) {
          return _foundMessage(msg, clearPersisted: false);
        }
      }
    }
    // Stale — the message is gone or never was what we expected. Forget it
    // so we don't keep retrying a dead id, and fall through to scanning.
    clearPersisted = true;
  }

  final result = await indexLookupRpc.history(0);
  WorkerProgress.report(0);
  if (result.error != null) {
    throw IndexRemoteException('Failed to read history: ${result.error!.errorMessage}');
  }

  for (final msg in extractMessages(result.result)) {
    if (msg is t.Message && msg.message.startsWith(indexMarker)) {
      return _foundMessage(msg, clearPersisted: clearPersisted);
    }
  }

  // Not in the recent window either. Before concluding the vault is empty
  // (which makes the next save fork a brand-new index), look much further
  // back — this is the fresh-install case with the search unavailable.
  final deep = await _scanForIndexMessages(maxMessages: _deepScanLimit);
  if (deep.hits.isNotEmpty) {
    return _foundMessage(deep.hits.first, clearPersisted: clearPersisted);
  }

  if (!searchOk && !deep.complete) {
    throw IndexRemoteException(
      'Could not search Saved Messages for the index, and the history scan '
      'stopped after ${deep.scanned} messages without reaching the start; '
      'not treating the vault as empty.',
    );
  }
  return RemoteIndexSnapshot(kind: RemoteIndexKind.none, clearPersisted: clearPersisted);
}

/// An index message found by the fallback lookup: a document (downloaded;
/// a download error is reported in the entry) or a legacy text message.
Future<RemoteIndexSnapshot> _foundMessage(t.Message msg, {required bool clearPersisted}) async {
  final media = msg.media;
  if (media is t.MessageMediaDocument && media.document is t.Document) {
    return RemoteIndexSnapshot(
      kind: RemoteIndexKind.single,
      docs: [await _fetchDoc(msg, null)],
      clearPersisted: clearPersisted,
    );
  }
  return RemoteIndexSnapshot(
    kind: RemoteIndexKind.legacy,
    legacyMessageId: msg.id,
    legacyPayload: msg.message.substring(indexMarker.length).trimLeft(),
    clearPersisted: clearPersisted,
  );
}

/// Walks history newest-first looking for index messages, up to
/// [maxMessages]. Only used when the search and the remembered id both came
/// up empty (fresh install, or search unavailable).
///
/// [complete] is true only when the scan reached the start of history (an
/// empty page); hitting [maxMessages] or a mid-scan error leaves it false.
Future<({List<t.Message> hits, bool complete, int scanned})> _scanForIndexMessages({
  required int maxMessages,
}) async {
  var offsetId = 0;
  var scanned = 0;
  while (scanned < maxMessages) {
    final result = await indexLookupRpc.history(offsetId);
    WorkerProgress.report(scanned);
    if (result.error != null) {
      if (scanned == 0) {
        throw IndexRemoteException('Failed to read history: ${result.error!.errorMessage}');
      }
      break;
    }
    final messages = extractMessages(result.result);
    if (messages.isEmpty) return (hits: const <t.Message>[], complete: true, scanned: scanned);
    scanned += messages.length;
    final hits = messages
        .whereType<t.Message>()
        .where((m) => m.message.startsWith(indexMarker))
        .toList();
    if (hits.isNotEmpty) return (hits: hits, complete: false, scanned: scanned);
    final ids = messages.map(_messageBaseId).whereType<int>().toList();
    if (ids.isEmpty) break;
    offsetId = ids.reduce((a, b) => a < b ? a : b);
  }
  return (hits: const <t.Message>[], complete: false, scanned: scanned);
}

/// Writes the index document, refusing to overwrite a document other than
/// [RemoteWriteArgs.expectedDocumentId], and verifies the write by reading
/// the message back.
///
/// Editing the existing message: upload the bytes, re-read the message (the
/// check sits right before the edit to keep the window in which another
/// writer can slip in as short as possible), return a conflict when it holds
/// another document, otherwise edit it in place and read it back. Never
/// creates a second index message while the existing one is there: an edit
/// error is an error. A new message is only created when there is no index
/// message yet (first save, legacy migration, or the message was deleted),
/// which is today's path.
Future<RemoteWriteResult> remoteWrite(RemoteWriteArgs args) async {
  final bytes = args.bytes.materialize().asUint8List();
  final inputFile = await _uploadBytes(bytes, indexFileName);
  final media = t.InputMediaUploadedDocument(
    nosoundVideo: false,
    forceFile: true,
    spoiler: false,
    file: inputFile,
    mimeType: 'application/json',
    attributes: [const t.DocumentAttributeFilename(fileName: indexFileName)],
  );

  final messageId = args.messageId;
  if (messageId != null && !args.legacy) {
    final current = await _readIndexMessage(messageId);
    if (current != null) {
      final currentDoc = _documentOf(current);
      if (currentDoc.id != args.expectedDocumentId) {
        return RemoteWriteResult.conflict(
          messageId: messageId,
          remoteBytes: TransferableTypedData.fromList([await downloadIndexDocument(currentDoc)]),
          remoteDocumentId: currentDoc.id,
        );
      }
      // Wrapped in a flood-wait retry: this same message gets edited once per
      // batch of changed files, exactly the pattern Telegram rate-limits.
      final result = await withFloodWaitRetry(() => TelegramService.instance.call(
            (c) => c.messages.editMessage(
              noWebpage: true,
              invertMedia: false,
              peer: const t.InputPeerSelf(),
              id: messageId,
              message: indexMarker,
              media: media,
            ),
          ));
      WorkerProgress.report(0);
      if (result.error != null) {
        throw IndexRemoteException('Failed to write index: ${result.error!.errorMessage}');
      }
      return _verifyWrite(
        messageId,
        bytes.length,
        editedDocumentId: _editedDocumentId(result.result, messageId),
        previousDocumentId: currentDoc.id,
      );
    }
    // The message is gone (deleted in Telegram): fall through and create a
    // fresh one, as before.
  }

  final staleId = args.legacy ? messageId : null; // legacy text message to clean up
  final randomId = randomInt64();
  final result = await withFloodWaitRetry(() => TelegramService.instance.call(
        (c) => c.messages.sendMedia(
          silent: true,
          background: false,
          clearDraft: false,
          noforwards: false,
          updateStickersetsOrder: false,
          invertMedia: false,
          allowPaidFloodskip: false,
          peer: const t.InputPeerSelf(),
          media: media,
          message: indexMarker,
          randomId: randomId,
        ),
      ));
  WorkerProgress.report(0);
  if (result.error != null) {
    throw IndexRemoteException('Failed to write index: ${result.error!.errorMessage}');
  }
  final newId = extractSentMessageId(result.result, randomId);
  if (newId == null) {
    throw IndexRemoteException('Index written but its message id is unknown.');
  }
  final verified = await _verifyWrite(newId, bytes.length);

  // Remove the superseded legacy text message so load won't see two — only
  // once the document replacing it is verified.
  if (staleId != null && !verified.conflict) {
    await TelegramService.instance.call(
      (c) => c.messages.deleteMessages(revoke: false, id: [staleId]),
    );
  }
  return verified;
}

/// The index message [messageId] if it still exists as an index document;
/// null when it is gone. Throws when the lookup itself fails (no write may
/// proceed on a guess).
Future<t.Message?> _readIndexMessage(int messageId) async {
  final result = await TelegramService.instance.call((c) => c.messages.getMessages(
        id: [t.InputMessageID(id: messageId)],
      ));
  WorkerProgress.report(0);
  if (result.error != null) {
    throw IndexRemoteException('Could not read the index message: ${result.error!.errorMessage}');
  }
  for (final m in extractMessages(result.result)) {
    if (m is t.Message && m.id == messageId && _isIndexDocument(m)) return m;
  }
  return null;
}

/// Reads [messageId] back after a write and checks it holds a document of
/// [length] bytes. When another writer replaced our document right after
/// the edit (its id differs from [editedDocumentId]), reports a conflict so
/// the caller rebases onto it and writes again.
Future<RemoteWriteResult> _verifyWrite(
  int messageId,
  int length, {
  int? editedDocumentId,
  int? previousDocumentId,
}) async {
  final msg = await _readIndexMessage(messageId);
  if (msg == null) {
    throw IndexRemoteException('Index write could not be verified: message missing.');
  }
  final doc = _documentOf(msg);
  if (editedDocumentId != null && doc.id != editedDocumentId) {
    return RemoteWriteResult.conflict(
      messageId: messageId,
      remoteBytes: TransferableTypedData.fromList([await downloadIndexDocument(doc)]),
      remoteDocumentId: doc.id,
    );
  }
  if (doc.id == previousDocumentId) {
    throw IndexRemoteException('Index write could not be verified: document unchanged.');
  }
  if (doc.size != length) {
    throw IndexRemoteException(
      'Index write could not be verified: size ${doc.size} != $length.',
    );
  }
  return RemoteWriteResult.written(messageId: messageId, documentId: doc.id);
}

/// The document id the edit result reports for [messageId], if any.
int? _editedDocumentId(t.UpdatesBase? updates, int messageId) {
  final list = switch (updates) {
    t.Updates(:final updates) => updates,
    t.UpdatesCombined(:final updates) => updates,
    t.UpdateShort(:final update) => [update],
    _ => const <t.UpdateBase>[],
  };
  for (final u in list) {
    final m = switch (u) {
      t.UpdateEditMessage(:final message) => message,
      t.UpdateEditChannelMessage(:final message) => message,
      _ => null,
    };
    if (m is t.Message && m.id == messageId && _isIndexDocument(m)) {
      return _documentOf(m).id;
    }
  }
  return null;
}

/// Which of [messageIds] still exist (chunks of 100); null on any error —
/// the caller then keeps every entry (never drops on doubt).
Future<List<int>?> remoteExistingMessageIds(List<int> messageIds) async {
  final existing = <int>[];
  for (var i = 0; i < messageIds.length; i += 100) {
    final chunk =
        messageIds.sublist(i, i + 100 > messageIds.length ? messageIds.length : i + 100);
    try {
      final result = await TelegramService.instance.call((c) => c.messages.getMessages(
            id: [for (final id in chunk) t.InputMessageID(id: id)],
          ));
      WorkerProgress.report(i);
      if (result.error != null) return null;
      for (final m in extractMessages(result.result)) {
        if (m is t.Message) existing.add(m.id);
      }
    } catch (_) {
      return null;
    }
  }
  return existing;
}

/// Deletes stale snapshot messages (revoke: false, result ignored), as the
/// consolidation in `IndexService.load` always did.
Future<void> remoteDeleteMessages(List<int> messageIds) async {
  if (messageIds.isEmpty) return;
  await TelegramService.instance.call(
    (c) => c.messages.deleteMessages(revoke: false, id: messageIds),
  );
}

/// See [IndexRemote.documentIdOf].
Future<int?> remoteDocumentIdOf(int messageId) async {
  try {
    final msg = await _readIndexMessage(messageId);
    return msg == null ? 0 : _documentOf(msg).id;
  } catch (_) {
    return null;
  }
}

/// See [IndexRemote.scanAllSnapshots].
Future<List<TransferableTypedData>> remoteScanAllSnapshots(int maxMessages) async {
  var offsetId = 0;
  var scanned = 0;
  final snapshots = <TransferableTypedData>[];

  while (scanned < maxMessages) {
    final result = await TelegramService.instance.call((c) => c.messages.getHistory(
          peer: const t.InputPeerSelf(),
          offsetId: offsetId,
          offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
          addOffset: 0,
          limit: 100,
          maxId: 0,
          minId: 0,
          hash: 0,
        ));
    WorkerProgress.report(scanned);
    if (result.error != null) break;
    final messages = extractMessages(result.result);
    if (messages.isEmpty) break;
    scanned += messages.length;

    for (final msg in messages) {
      if (msg is t.Message && msg.message.startsWith(indexMarker)) {
        final media = msg.media;
        if (media is t.MessageMediaDocument && media.document is t.Document) {
          try {
            final bytes = await downloadIndexDocument(media.document as t.Document);
            snapshots.add(TransferableTypedData.fromList([bytes]));
          } catch (_) {
            // Corrupt/partial snapshot — skip it, keep scanning for others.
          }
        }
      }
    }

    final ids = messages.map(_messageBaseId).whereType<int>().toList();
    if (ids.isEmpty) break;
    offsetId = ids.reduce((a, b) => a < b ? a : b);
  }
  return snapshots;
}

/// The message id out of any [t.MessageBase] variant `messages.getHistory`
/// can return.
int? _messageBaseId(t.MessageBase m) => switch (m) {
      t.Message(:final id) => id,
      t.MessageService(:final id) => id,
      t.MessageEmpty(:final id) => id,
      _ => null,
    };

/// Uploads [bytes] as document parts and returns the InputFile reference.
/// The index is small enough to use the regular (non-big) upload path.
Future<t.InputFile> _uploadBytes(Uint8List bytes, String name) async {
  final fileId = randomInt64();
  const chunkSize = UploadLimits.chunkSize;
  final totalParts = (bytes.length + chunkSize - 1) ~/ chunkSize;

  for (var part = 0; part < totalParts; part++) {
    final start = part * chunkSize;
    final end = (start + chunkSize) < bytes.length ? start + chunkSize : bytes.length;
    final chunk = Uint8List.sublistView(bytes, start, end);
    final result = await TelegramService.instance.call(
      (c) => c.upload.saveFilePart(
        fileId: fileId,
        filePart: part,
        bytes: chunk,
      ),
    );
    WorkerProgress.report(part);
    if (result.error != null) {
      throw IndexRemoteException(
        'Index upload failed at part $part: ${result.error!.errorMessage}',
      );
    }
  }

  return t.InputFile(
    id: fileId,
    parts: totalParts == 0 ? 1 : totalParts,
    name: name,
    md5Checksum: '',
  );
}

/// Downloads an index document's bytes.
Future<Uint8List> downloadIndexDocument(t.Document doc) async {
  final location = t.InputDocumentFileLocation(
    id: doc.id,
    accessHash: doc.accessHash,
    fileReference: doc.fileReference,
    thumbSize: '',
  );
  final builder = BytesBuilder(copy: false);
  for (final range in downloadRanges(doc.size)) {
    final result = await TelegramService.instance.call((c) => c.upload.getFile(
          precise: false,
          cdnSupported: false,
          location: location,
          offset: range.offset,
          limit: range.limit,
        ));
    WorkerProgress.report(range.offset);
    if (result.error != null) {
      throw IndexRemoteException('Index download failed: ${result.error!.errorMessage}');
    }
    final file = result.result;
    if (file is! t.UploadFile) {
      throw IndexRemoteException('Unexpected getFile response for index.');
    }
    builder.add(file.bytes);
    if (file.bytes.length < range.limit) break;
  }
  return builder.toBytes();
}
