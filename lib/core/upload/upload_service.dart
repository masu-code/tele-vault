import 'dart:io';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:t/t.dart' as t;
import 'package:uuid/uuid.dart';
import '../../models/file_item.dart';
import '../../models/file_part.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import 'upload_plan.dart';

const _uuid = Uuid();

/// Uploads local files to Telegram and produces the [FileItem] to record in the
/// index. Large files are split into multiple documents (segments) that are
/// reassembled on download; each segment is uploaded in 512 KB parts.
///
/// Files currently land in the user's Saved Messages (InputPeerSelf). A future
/// phase can move storage to a dedicated private channel without changing the
/// public surface of this service.
class UploadService {
  UploadService._();
  static final UploadService instance = UploadService._();

  /// Serializes every upload app-wide. There are multiple independent
  /// callers (the bulk transfer queue, BackupService's per-album auto-sync,
  /// on-demand single-asset uploads) that can legitimately fire at the same
  /// time — e.g. auto-backup for a previously-enabled album kicking off at
  /// startup while the transfer queue is also mid-upload. Running two
  /// multi-part uploads concurrently over the same Telegram connection
  /// corrupted the session's protocol state badly enough that the server
  /// killed it outright (AUTH_KEY_UNREGISTERED), rather than just
  /// flood-waiting. Chaining every call through here — the same pattern as
  /// IndexNotifier's `_writeChain` and IoSocket's `_sendChain` — guarantees
  /// uploads never overlap, without slowing down any single upload's own
  /// throughput (each still runs at full speed, just strictly one at a time).
  Future<void> _chain = Future.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    _chain = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Uploads [file] and returns the resulting [FileItem]. [onProgress] is
  /// called with a 0..1 fraction as bytes are sent.
  ///
  /// [maxSegmentSizeOverride] exists only so integration tests can force a
  /// small file through the multi-segment (>2GB-file) path without actually
  /// uploading gigabytes of data; production code must never pass it.
  Future<FileItem> uploadFile(
    File file, {
    String? folderId,
    void Function(double progress)? onProgress,
    int? maxSegmentSizeOverride,
  }) =>
      _serialized(() => _uploadFile(
            file,
            folderId: folderId,
            onProgress: onProgress,
            maxSegmentSizeOverride: maxSegmentSizeOverride,
          ));

  Future<FileItem> _uploadFile(
    File file, {
    String? folderId,
    void Function(double progress)? onProgress,
    int? maxSegmentSizeOverride,
  }) async {
    final totalSize = await file.length();
    if (totalSize == 0) {
      throw UploadException('Cannot upload an empty file.');
    }

    final name = p.basename(file.path);
    final mime = lookupMimeType(name) ?? 'application/octet-stream';
    final segments = planSegments(
      totalSize,
      maxSegmentSize: maxSegmentSizeOverride ?? UploadLimits.maxSegmentSize,
    );

    final raf = await file.open();
    final parts = <FilePart>[];
    var uploadedBytes = 0;
    try {
      for (final seg in segments) {
        final int messageId;
        try {
          messageId = await _uploadSegment(
            raf,
            seg,
            name,
            mime,
            segments.length,
            (chunkBytes) {
              uploadedBytes += chunkBytes;
              onProgress?.call(uploadedBytes / totalSize);
            },
          );
        } catch (e) {
          // A multi-segment file (>2GB) sends each segment as its own
          // Telegram message. If segment N fails after segments 1..N-1
          // already succeeded, those messages would otherwise sit orphaned
          // in Saved Messages forever — this FileItem never gets created, so
          // nothing in the index would ever reference them for cleanup.
          if (parts.isNotEmpty) {
            try {
              await TelegramService.instance.call((c) => c.messages.deleteMessages(
                    revoke: true,
                    id: [for (final p in parts) p.messageId],
                  ));
            } catch (_) {
              // Best-effort cleanup — the original upload failure is what
              // matters to the caller either way.
            }
          }
          rethrow;
        }
        parts.add(FilePart(messageId: messageId, part: seg.index, size: seg.size));
      }
    } finally {
      await raf.close();
    }

    return FileItem(
      id: _uuid.v4(),
      name: name,
      folderId: folderId,
      totalSize: totalSize,
      mimeType: mime,
      createdAt: DateTime.now().toUtc(),
      parts: parts,
    );
  }

  /// Uploads one segment as a single Telegram document, returning its message
  /// id in the storage chat.
  Future<int> _uploadSegment(
    RandomAccessFile raf,
    UploadSegment seg,
    String name,
    String mime,
    int totalSegments,
    void Function(int chunkBytes) onChunk,
  ) async {
    final fileId = randomInt64();
    final totalParts = seg.chunkCount();
    final isBig = seg.isBig;

    await raf.setPosition(seg.offset);
    var remaining = seg.size;
    var partIndex = 0;
    while (remaining > 0) {
      final toRead =
          remaining < UploadLimits.chunkSize ? remaining : UploadLimits.chunkSize;
      final bytes = await raf.read(toRead);

      // bytes is captured in the lambda; on reconnect the same part is retried.
      final result = isBig
          ? await withAuthKeyRetry(() => TelegramService.instance.call((c) => c.upload.saveBigFilePart(
                fileId: fileId,
                filePart: partIndex,
                fileTotalParts: totalParts,
                bytes: bytes,
              )))
          : await withAuthKeyRetry(() => TelegramService.instance.call((c) => c.upload.saveFilePart(
                fileId: fileId,
                filePart: partIndex,
                bytes: bytes,
              )));

      if (result.error != null) {
        throw UploadException(
          'Failed at part $partIndex/$totalParts: ${result.error!.errorMessage}',
        );
      }

      remaining -= toRead;
      partIndex++;
      onChunk(toRead);
    }

    // For a multi-segment file, tag each document so it is recognizable in the
    // chat; the user-facing name stays the original in the index.
    final segName = totalSegments > 1 ? '$name.part${seg.index}' : name;

    final media = t.InputMediaUploadedDocument(
      nosoundVideo: false,
      forceFile: true,
      spoiler: false,
      file: isBig
          ? t.InputFileBig(id: fileId, parts: totalParts, name: segName)
          : t.InputFile(id: fileId, parts: totalParts, name: segName, md5Checksum: ''),
      mimeType: mime,
      attributes: [t.DocumentAttributeFilename(fileName: segName)],
    );

    final randomId = randomInt64();
    final result = await withAuthKeyRetry(() => TelegramService.instance.call((c) => c.messages.sendMedia(
      silent: true,
      background: false,
      clearDraft: false,
      noforwards: false,
      updateStickersetsOrder: false,
      invertMedia: false,
      allowPaidFloodskip: false,
      peer: const t.InputPeerSelf(),
      media: media,
      message: '',
      randomId: randomId,
    )));

    if (result.error != null) {
      throw UploadException('sendMedia failed: ${result.error!.errorMessage}');
    }

    final messageId = extractSentMessageId(result.result, randomId);
    if (messageId == null) {
      throw UploadException('Upload sent but message id could not be resolved.');
    }
    return messageId;
  }
}

class UploadException implements Exception {
  final String message;
  UploadException(this.message);
  @override
  String toString() => 'UploadException: $message';
}
