import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:t/t.dart' as t;
import '../../models/file_item.dart';
import '../backup/backup_registry.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import 'download_plan.dart';

/// Downloads a [FileItem] from Telegram, reassembling its segments (parts) into
/// a single local file in order.
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

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

        // Each document's own byte ranges start at 0 — baseOffset shifts them
        // to this part's actual position in the reassembled output file.
        final baseOffset = written;
        written += await _downloadDocument(
          location: location,
          size: doc.size,
          baseOffset: baseOffset,
          sink: sink,
          onChunk: (n) => onProgress
              ?.call(item.totalSize == 0 ? 1 : (baseOffset + n) / item.totalSize),
        );
      }
    } catch (e) {
      await sink.close();
      // Delete rather than leave a partial file behind: downloadToCache's
      // completeness check only compares length to totalSize, so a
      // half-written file that happens to reach that length anyway (a range
      // failed in the middle while later ranges still got written, pushing
      // the file's length past the hole) would otherwise be silently served
      // as "complete" forever on every future retry.
      if (await out.exists()) await out.delete();
      rethrow;
    }
    await sink.close();
    return out;
  }

  /// Fetches [size] bytes at [location] as several 1 MB windows in parallel
  /// (bounded concurrency) and writes each to [sink] at [baseOffset] + its
  /// offset within this document. Writes are serialized with a lock since
  /// concurrent `setPosition` + `writeFrom` pairs on the same handle would
  /// otherwise race; the network requests — the actual bottleneck — still run
  /// concurrently. Returns the total bytes written.
  Future<int> _downloadDocument({
    required t.InputDocumentFileLocation location,
    required int size,
    required int baseOffset,
    required RandomAccessFile sink,
    void Function(int bytesSoFar)? onChunk,
  }) async {
    const concurrency = 4;
    final ranges = downloadRanges(size);
    var nextIndex = 0;
    var completed = 0;
    var writeLock = Future<void>.value();
    // Future.wait below defaults to eagerError: false, so it waits for every
    // worker to finish before throwing — if left unchecked, the other 3
    // workers would keep fetching and writing ranges after one fails,
    // extending the file past the failed range's hole and potentially past
    // the point where its length matches totalSize, so the completeness
    // check would treat the corrupted file as valid forever. Recording the
    // first failure here and having every worker bail out on it stops that.
    Object? failure;

    Future<void> worker() async {
      while (failure == null) {
        final i = nextIndex;
        if (i >= ranges.length) return;
        nextIndex++;
        final range = ranges[i];

        try {
          final result = await TelegramService.instance.call((c) => c.upload.getFile(
            precise: false,
            cdnSupported: false,
            location: location,
            offset: range.offset,
            limit: range.limit,
          ));
          if (result.error != null) {
            throw DownloadException('getFile failed: ${result.error!.errorMessage}');
          }
          final file = result.result;
          if (file is! t.UploadFile) {
            throw DownloadException('Unexpected getFile response type.');
          }
          final bytes = file.bytes;
          if (bytes.isEmpty) continue;

          final prior = writeLock;
          final done = Completer<void>();
          writeLock = done.future;
          await prior;
          try {
            await sink.setPosition(baseOffset + range.offset);
            await sink.writeFrom(bytes);
          } finally {
            done.complete();
          }

          completed += bytes.length;
          onChunk?.call(completed);
        } catch (e) {
          failure ??= e;
          return;
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    if (failure != null) throw failure!;
    return completed;
  }

  /// Downloads [item] into a temporary cache and returns the cached file,
  /// reusing it if already present (used for in-app preview). Cached under a
  /// per-file-id folder so names with the original extension are preserved.
  ///
  /// If [item] was uploaded from a local file that still exists on the
  /// device (device backup / manual upload), that original file is returned
  /// directly — no Telegram request at all. This is both faster and works
  /// offline, and it's always at least as complete as the cloud copy since
  /// it's the exact file that was uploaded.
  Future<File> downloadToCache(
    FileItem item, {
    void Function(double progress)? onProgress,
  }) async {
    final linked = BackupRegistry.instance.localPathFor(item.id);
    if (linked != null) {
      final local = File(linked);
      if (await local.exists()) {
        onProgress?.call(1);
        return local;
      }
    }

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
    final result = await TelegramService.instance.call(
      (c) => c.messages.getMessages(id: [t.InputMessageID(id: messageId)]),
    );
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
