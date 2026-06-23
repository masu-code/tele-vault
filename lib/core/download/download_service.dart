import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:t/t.dart' as t;
import '../../models/file_item.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import 'download_plan.dart';

/// Downloads a [FileItem] from Telegram, reassembling its segments (parts) into
/// a single local file in order.
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  t.Client get _client => TelegramService.instance.client;

  /// Downloads [item] into [destDir] and returns the written file. Parts are
  /// fetched and appended in order, so the output is the original file even
  /// when it was split across multiple Telegram documents.
  Future<File> downloadFile(
    FileItem item, {
    required String destDir,
    void Function(double progress)? onProgress,
  }) async {
    final out = File(p.join(destDir, item.name));
    final sink = await out.open(mode: FileMode.write);
    var written = 0;

    try {
      final ordered = [...item.parts]..sort((a, b) => a.part.compareTo(b.part));
      for (final part in ordered) {
        final doc = await _fetchDocument(part.messageId);
        final location = t.InputDocumentFileLocation(
          id: doc.id,
          accessHash: doc.accessHash,
          fileReference: doc.fileReference,
          thumbSize: '',
        );

        for (final range in downloadRanges(doc.size)) {
          final result = await _client.upload.getFile(
            precise: false,
            cdnSupported: false,
            location: location,
            offset: range.offset,
            limit: range.limit,
          );
          if (result.error != null) {
            throw DownloadException('getFile failed: ${result.error!.errorMessage}');
          }
          final file = result.result;
          if (file is! t.UploadFile) {
            throw DownloadException('Unexpected getFile response type.');
          }
          final bytes = file.bytes;
          if (bytes.isEmpty) break;

          await sink.writeFrom(bytes);
          written += bytes.length;
          onProgress?.call(item.totalSize == 0 ? 1 : written / item.totalSize);

          // A short read means we reached the end of this document.
          if (bytes.length < range.limit) break;
        }
      }
    } finally {
      await sink.close();
    }
    return out;
  }

  /// Fetches the [t.Document] backing a stored part by its message id. The
  /// file reference is read fresh here because Telegram references expire.
  Future<t.Document> _fetchDocument(int messageId) async {
    final result =
        await _client.messages.getMessages(id: [t.InputMessageID(id: messageId)]);
    if (result.error != null) {
      throw DownloadException('getMessages failed: ${result.error!.errorMessage}');
    }

    for (final m in extractMessages(result.result)) {
      if (m is t.Message) {
        final media = m.media;
        if (media is t.MessageMediaDocument) {
          final doc = media.document;
          if (doc is t.Document) return doc;
        }
      }
    }
    throw DownloadException('No document found in message $messageId.');
  }
}

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => 'DownloadException: $message';
}
