import 'dart:convert';
import 'dart:typed_data';
import 'package:t/t.dart' as t;
import '../../models/file_index.dart';
import '../../models/file_item.dart';
import '../backup/backup_registry.dart';
import '../download/download_plan.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import '../upload/upload_plan.dart';

/// Reads and writes the vault index to the user's Telegram "Saved Messages".
///
/// The index is stored as an uploaded JSON document (`televault_index.json`)
/// whose message caption is [_marker], so it can be found again on any device.
/// Storing it as a document — rather than a plain text message — removes the
/// 4096-character cap a text message would impose, letting the index hold
/// effectively unlimited entries.
///
/// Backward compatible: an older text-message index (caption starts with
/// [_marker], no media) is read and then rewritten as a document on the next
/// save, and the stale text message is deleted.
class IndexService {
  IndexService._();
  static final IndexService instance = IndexService._();

  static const String _marker = 'TELEVAULT_INDEX_V1';
  static const String _fileName = 'televault_index.json';

  /// Message id of the current index message, once known.
  int? _messageId;

  /// True when [_messageId] points at a legacy text message that must be
  /// replaced (not edited) by a document on the next save.
  bool _legacy = false;

  int? get messageId => _messageId;

  /// True after [load] reads a legacy text-message index, signalling the caller
  /// to persist once so it gets rewritten as a document.
  bool get needsMigration => _legacy;

  /// Loads the index, scanning the most recent Saved Messages for the tagged
  /// message. Returns an empty index if none exists yet.
  ///
  /// Only checks the most recent page (100 messages) — this runs on every
  /// cold start and must stay fast even on an account with years of
  /// unrelated Saved Messages history; a full scan here previously froze the
  /// main isolate long enough to trigger Android's "not responding" dialog.
  /// The known gap: every uploaded file also posts its own message into this
  /// same peer, so if the app process restarts after ~100+ files have been
  /// uploaded since the index was last touched, this won't find it and
  /// treats the vault as empty — see [findAllIndexSnapshots] for the
  /// recovery tool that reunites index snapshots orphaned that way (run
  /// deliberately, off the main isolate, not from here).
  Future<FileIndex> load() async {
    final result = await TelegramService.instance.call((c) => c.messages.getHistory(
      peer: const t.InputPeerSelf(),
      offsetId: 0,
      offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
      addOffset: 0,
      limit: 100,
      maxId: 0,
      minId: 0,
      hash: 0,
    ));
    if (result.error != null) {
      throw IndexException('Failed to read history: ${result.error!.errorMessage}');
    }

    for (final msg in extractMessages(result.result)) {
      if (msg is! t.Message || !msg.message.startsWith(_marker)) continue;

      final media = msg.media;
      if (media is t.MessageMediaDocument && media.document is t.Document) {
        // Current format: index stored as a document.
        _messageId = msg.id;
        _legacy = false;
        final bytes = await _downloadDocument(media.document as t.Document);
        final raw = utf8.decode(bytes);
        try {
          return FileIndex.decode(raw);
        } catch (e) {
          throw IndexException('Index document is corrupt: $e');
        }
      } else {
        // Legacy format: JSON inline after the marker in a text message.
        _messageId = msg.id;
        _legacy = true;
        final payload = msg.message.substring(_marker.length).trimLeft();
        if (payload.isEmpty) return FileIndex.empty();
        try {
          return FileIndex.decode(payload);
        } catch (e) {
          throw IndexException('Legacy index message is corrupt: $e');
        }
      }
    }

    _messageId = null;
    _legacy = false;
    return FileIndex.empty();
  }

  /// Persists [index] as a JSON document. Edits the existing index document in
  /// place when possible; otherwise uploads a new one and removes any stale
  /// (or legacy) index message.
  Future<void> save(FileIndex index) async {
    final bytes = Uint8List.fromList(utf8.encode(index.encode()));
    final inputFile = await _uploadBytes(bytes, _fileName);
    final media = t.InputMediaUploadedDocument(
      nosoundVideo: false,
      forceFile: true,
      spoiler: false,
      file: inputFile,
      mimeType: 'application/json',
      attributes: [const t.DocumentAttributeFilename(fileName: _fileName)],
    );

    // Edit the existing document message in place when we have one. Wrapped
    // in a flood-wait retry: this same message gets edited once per changed
    // file, so uploading/backing-up several files in quick succession is
    // exactly the pattern Telegram rate-limits — without retrying, a later
    // file in the batch would finish uploading but never make it into the
    // index, becoming invisible everywhere in the app despite already
    // consuming Telegram storage.
    if (_messageId != null && !_legacy) {
      final result = await withFloodWaitRetry(() => TelegramService.instance.call(
            (c) => c.messages.editMessage(
              noWebpage: true,
              invertMedia: false,
              peer: const t.InputPeerSelf(),
              id: _messageId!,
              message: _marker,
              media: media,
            ),
          ));
      if (result.error == null) return;
      // The message may be gone; fall through to create a fresh one.
      _messageId = null;
    }

    // Create a new index document.
    final staleId = _messageId; // legacy text message to clean up, if any
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
            message: _marker,
            randomId: randomId,
          ),
        ));
    if (result.error != null) {
      throw IndexException('Failed to write index: ${result.error!.errorMessage}');
    }
    _messageId = extractSentMessageId(result.result, randomId);
    _legacy = false;

    // Remove the superseded legacy text message so load() won't see two.
    if (staleId != null) {
      await TelegramService.instance.call(
        (c) => c.messages.deleteMessages(revoke: false, id: [staleId]),
      );
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
      if (result.error != null) {
        throw IndexException('Index upload failed at part $part: ${result.error!.errorMessage}');
      }
    }

    return t.InputFile(
      id: fileId,
      parts: totalParts == 0 ? 1 : totalParts,
      name: name,
      md5Checksum: '',
    );
  }

  /// Scans the *entire* Saved Messages history (not just the recent window
  /// [load] checks) for every message tagged as an index snapshot, and
  /// returns each decoded snapshot oldest-first.
  ///
  /// [load] only looks at the most recent 100 messages. Every uploaded file
  /// also posts its own message into the same Saved Messages peer, so once
  /// enough files have been uploaded since the index was last touched, the
  /// index message itself gets pushed outside that window. If the app
  /// process restarts at that point, [load] can't find it, treats the vault
  /// as empty, and the next save creates a brand-new index message —
  /// orphaning the old one (still sitting in history, never deleted) instead
  /// of building on it. This is the recovery/diagnostic tool for that: it
  /// finds every such snapshot so their file lists can be merged back
  /// together into one consolidated index.
  Future<List<FileIndex>> findAllIndexSnapshots({int maxMessages = 20000}) async {
    var offsetId = 0;
    var scanned = 0;
    final snapshots = <FileIndex>[];

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
      if (result.error != null) break;
      final messages = extractMessages(result.result);
      if (messages.isEmpty) break;
      scanned += messages.length;

      for (final msg in messages) {
        if (msg is t.Message && msg.message.startsWith(_marker)) {
          final media = msg.media;
          if (media is t.MessageMediaDocument && media.document is t.Document) {
            try {
              final bytes = await _downloadDocument(media.document as t.Document);
              snapshots.add(FileIndex.decode(utf8.decode(bytes)));
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

    return snapshots.reversed.toList(); // oldest first
  }

  /// The message id out of any [t.MessageBase] variant [messages.getHistory]
  /// can return — the base type itself doesn't expose `id` since not every
  /// variant (e.g. a hypothetical future one) is guaranteed to have one.
  int? _messageBaseId(t.MessageBase m) => switch (m) {
        t.Message(:final id) => id,
        t.MessageService(:final id) => id,
        t.MessageEmpty(:final id) => id,
        _ => null,
      };

  Future<Uint8List> _downloadDocument(t.Document doc) async {
    final location = t.InputDocumentFileLocation(
      id: doc.id,
      accessHash: doc.accessHash,
      fileReference: doc.fileReference,
      thumbSize: '',
    );
    final builder = BytesBuilder();
    for (final range in downloadRanges(doc.size)) {
      final result = await TelegramService.instance.call((c) => c.upload.getFile(
        precise: false,
        cdnSupported: false,
        location: location,
        offset: range.offset,
        limit: range.limit,
      ));
      if (result.error != null) {
        throw IndexException('Index download failed: ${result.error!.errorMessage}');
      }
      final file = result.result;
      if (file is! t.UploadFile) {
        throw IndexException('Unexpected getFile response for index.');
      }
      builder.add(file.bytes);
      if (file.bytes.length < range.limit) break;
    }
    return builder.toBytes();
  }
}

class IndexException implements Exception {
  final String message;
  IndexException(this.message);
  @override
  String toString() => 'IndexException: $message';
}
