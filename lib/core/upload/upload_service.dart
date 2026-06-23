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

  t.Client get _client => TelegramService.instance.client;

  /// Uploads [file] and returns the resulting [FileItem]. [onProgress] is
  /// called with a 0..1 fraction as bytes are sent.
  Future<FileItem> uploadFile(
    File file, {
    String? folderId,
    void Function(double progress)? onProgress,
  }) async {
    final totalSize = await file.length();
    if (totalSize == 0) {
      throw UploadException('Cannot upload an empty file.');
    }

    final name = p.basename(file.path);
    final mime = lookupMimeType(name) ?? 'application/octet-stream';
    final segments = planSegments(totalSize);

    final raf = await file.open();
    final parts = <FilePart>[];
    var uploadedBytes = 0;
    try {
      for (final seg in segments) {
        final messageId = await _uploadSegment(
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

      final result = isBig
          ? await _client.upload.saveBigFilePart(
              fileId: fileId,
              filePart: partIndex,
              fileTotalParts: totalParts,
              bytes: bytes,
            )
          : await _client.upload.saveFilePart(
              fileId: fileId,
              filePart: partIndex,
              bytes: bytes,
            );

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
      forceFile: true, // keep the bytes verbatim, no video/photo auto-detection
      spoiler: false,
      file: isBig
          ? t.InputFileBig(id: fileId, parts: totalParts, name: segName)
          : t.InputFile(id: fileId, parts: totalParts, name: segName, md5Checksum: ''),
      mimeType: mime,
      attributes: [t.DocumentAttributeFilename(fileName: segName)],
    );

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
      message: '',
      randomId: randomId,
    );

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
