import 'dart:convert';
import 'dart:typed_data';
import 'package:t/t.dart' as t;
import '../../models/file_index.dart';
import '../../models/file_item.dart';
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

  t.Client get _client => TelegramService.instance.client;

  /// Loads the index, scanning recent Saved Messages for the tagged message.
  /// Returns an empty index if none exists yet.
  Future<FileIndex> load() async {
    final result = await _client.messages.getHistory(
      peer: const t.InputPeerSelf(),
      offsetId: 0,
      offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
      addOffset: 0,
      limit: 100,
      maxId: 0,
      minId: 0,
      hash: 0,
    );
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

    // Edit the existing document message in place when we have one.
    if (_messageId != null && !_legacy) {
      final result = await _client.messages.editMessage(
        noWebpage: true,
        invertMedia: false,
        peer: const t.InputPeerSelf(),
        id: _messageId!,
        message: _marker,
        media: media,
      );
      if (result.error == null) return;
      // The message may be gone; fall through to create a fresh one.
      _messageId = null;
    }

    // Create a new index document.
    final staleId = _messageId; // legacy text message to clean up, if any
    final randomId = randomInt64();
    final result = await _client.messages.sendMedia(
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
    );
    if (result.error != null) {
      throw IndexException('Failed to write index: ${result.error!.errorMessage}');
    }
    _messageId = extractSentMessageId(result.result, randomId);
    _legacy = false;

    // Remove the superseded legacy text message so load() won't see two.
    if (staleId != null) {
      await _client.messages.deleteMessages(revoke: false, id: [staleId]);
    }
  }

  /// Permanently deletes the given files' messages (all parts) from Telegram,
  /// freeing the storage. The index update is the caller's responsibility.
  Future<void> deleteFromTelegram(List<FileItem> items) async {
    final ids = <int>[
      for (final item in items)
        for (final part in item.parts) part.messageId,
    ];
    if (ids.isEmpty) return;
    // deleteMessages caps at ~100 ids per call; chunk to be safe.
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
      await _client.messages.deleteMessages(revoke: true, id: chunk);
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
      final result = await _client.upload.saveFilePart(
        fileId: fileId,
        filePart: part,
        bytes: Uint8List.sublistView(bytes, start, end),
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

  Future<Uint8List> _downloadDocument(t.Document doc) async {
    final location = t.InputDocumentFileLocation(
      id: doc.id,
      accessHash: doc.accessHash,
      fileReference: doc.fileReference,
      thumbSize: '',
    );
    final builder = BytesBuilder();
    for (final range in downloadRanges(doc.size)) {
      final result = await _client.upload.getFile(
        precise: false,
        cdnSupported: false,
        location: location,
        offset: range.offset,
        limit: range.limit,
      );
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
