import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
        final doc = await fetchDocument(part.messageId);
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

  /// Downloads [item] into a temporary cache and returns the cached file,
  /// reusing it if already present (used for in-app preview). Cached under a
  /// per-file-id folder so names with the original extension are preserved.
  Future<File> downloadToCache(
    FileItem item, {
    void Function(double progress)? onProgress,
  }) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'televault_cache', item.id));
    await dir.create(recursive: true);
    final cached = File(p.join(dir.path, item.name));

    if (await cached.exists() && await cached.length() == item.totalSize) {
      onProgress?.call(1);
      return cached;
    }
    return downloadFile(item, destDir: dir.path, onProgress: onProgress);
  }

  /// Fetches the [t.Document] backing a stored part by its message id. The
  /// file reference is read fresh here because Telegram references expire.
  /// Public so the thumbnail service can read a video's embedded thumbnail.
  Future<t.Document> fetchDocument(int messageId) async {
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
