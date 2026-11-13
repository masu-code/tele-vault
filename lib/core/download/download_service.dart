import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:t/t.dart' as t;
import '../../models/file_item.dart';
import '../backup/backup_registry.dart';
import '../telegram/client.dart';
import '../telegram/io_socket.dart' show SocketDeadException;
import '../telegram/tg_utils.dart';
import 'download_plan.dart';
import 'download_worker.dart';

/// Downloads a [FileItem] from Telegram, reassembling its segments (parts) into
/// a single local file in order.
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  /// Downloads [item] into [destDir] and returns the written file. Parts are
  /// fetched and appended in order, so the output is the original file even
  /// when it was split across multiple Telegram documents.
  ///
  /// On the app's main isolate this runs on [DownloadWorker] so the AES
  /// decryption of every chunk stays off the UI thread.
  Future<File> downloadFile(
    FileItem item, {
    required String destDir,
    void Function(double progress)? onProgress,
  }) async {
    if (DownloadWorker.enabled) {
      return File(await DownloadWorker.instance
          .downloadFile(item, destDir: destDir, onProgress: onProgress));
    }
    return _downloadFile(item, destDir: destDir, onProgress: onProgress);
  }

  Future<File> _downloadFile(
    FileItem item, {
    required String destDir,
    void Function(double progress)? onProgress,
  }) {
    // A FLOOD_WAIT inside TelegramService.call reports through WorkerProgress
    // every 10 s while it waits; repeating the last progress value then lets
    // the caller's inactivity timeout (worker request, viewer) see a download
    // that is waiting out a flood as alive instead of failing it as stalled.
    var last = 0.0;
    void progress(double value) {
      last = value;
      onProgress?.call(value);
    }

    return WorkerProgress.runReporting<File>(
      (_) => onProgress?.call(last),
      () => _downloadFileBody(item, destDir: destDir, onProgress: progress),
    );
  }

  Future<File> _downloadFileBody(
    FileItem item, {
    required String destDir,
    required void Function(double progress) onProgress,
  }) async {
    final out = File(p.join(destDir, item.name));
    // Written to a unique temp file and renamed into place on success: a retry
    // after the inactivity timeout can run a second download of the same file
    // while the first is still alive, and a shared output path let the first
    // one's failure delete the file the second was writing.
    final tmp = File('${out.path}.${_randomSuffix()}.part');
    final sink = await tmp.open(mode: FileMode.write);
    var written = 0;
    final ordered = [...item.parts]..sort((a, b) => a.part.compareTo(b.part));
    var partNo = 0;

    try {
      for (final part in ordered) {
        partNo++;
        final doc = await _fetchDocumentWithRetry(part.messageId);
        // Each document's own byte ranges start at 0 — baseOffset shifts them
        // to this part's actual position in the reassembled output file.
        final baseOffset = written;
        void report(int n) =>
            onProgress(item.totalSize == 0 ? 1 : (baseOffset + n) / item.totalSize);
        // Keep-alive: resolving the part's document (on a stale connection
        // that includes a reconnect) is progress too.
        report(0);
        written += await _downloadDocument(
          doc: doc,
          messageId: part.messageId,
          baseOffset: baseOffset,
          sink: sink,
          onChunk: report,
        );
      }
      if (written != item.totalSize) {
        // Not fatal (the bytes are Telegram's), but the cache's completeness
        // check compares against totalSize, so this file is fetched again on
        // every open.
        debugPrint('TVDIAG: download size mismatch parts=${ordered.length} '
            'delta=${written - item.totalSize}');
      }
    } catch (e) {
      final partLabel = '$partNo/${ordered.length}';
      debugPrint('TVDIAG: download failed ${downloadFailureReason(e, part: partLabel)}');
      await sink.close();
      // Delete rather than leave a partial file behind: downloadToCache's
      // completeness check only compares length to totalSize, so a
      // half-written file that happens to reach that length anyway (a range
      // failed in the middle while later ranges still got written, pushing
      // the file's length past the hole) would otherwise be silently served
      // as "complete" forever on every future retry.
      // Only our own temp file: a concurrent download owns a different one.
      if (await tmp.exists()) await tmp.delete();
      if (e is DownloadException && e.part == null) throw e.withPart(partLabel);
      rethrow;
    }
    try {
      await sink.close();
      await tmp.rename(out.path);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      // The rename can lose to a concurrent download of the same file that
      // already put a complete copy in place (Windows refuses to replace a
      // file the player holds open): that copy is as good as ours.
      if (await out.exists() && await out.length() == written) return out;
      debugPrint('TVDIAG: download failed stage=rename code=${e.runtimeType}');
      rethrow;
    }
    return out;
  }

  static final _rng = Random();
  static String _randomSuffix() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rng.nextInt(1 << 32).toRadixString(36)}';

  /// How many times one getFile window (or one getMessages) is sent again
  /// after a transport failure (timeout, dead socket) that
  /// [TelegramService.call]'s own reconnect-and-retry did not get past — the
  /// first request of a big file on a fresh or stale connection.
  static const int transientRetries = 1;

  /// How many times one window refreshes the document's file reference
  /// (getMessages) after a FILE_REFERENCE_* error before failing.
  static const int referenceRefreshes = 2;

  /// Test seam: replaces the getFile RPC (null: [TelegramService.call]).
  @visibleForTesting
  Future<t.Result<t.UploadFileBase>> Function(
    t.InputDocumentFileLocation location,
    int offset,
    int limit,
  )? debugGetFile;

  /// Test seam: replaces [fetchDocument] inside downloads.
  @visibleForTesting
  Future<t.Document> Function(int messageId)? debugFetchDocument;

  /// Test seam: getFile window size (null: [DownloadLimits.chunkSize]).
  @visibleForTesting
  int? debugChunkSize;

  Future<t.Result<t.UploadFileBase>> _getFile(
    t.InputDocumentFileLocation location,
    int offset,
    int limit,
  ) {
    final fake = debugGetFile;
    if (fake != null) return fake(location, offset, limit);
    return TelegramService.instance.call((c) => c.upload.getFile(
          precise: false,
          cdnSupported: false,
          location: location,
          offset: offset,
          limit: limit,
        ));
  }

  /// [fetchDocument], sent once more after a transport failure; any other
  /// failure surfaces as a [DownloadException] with stage `getMessages`.
  Future<t.Document> _fetchDocumentWithRetry(int messageId) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await (debugFetchDocument ?? fetchDocument)(messageId);
      } catch (e) {
        if (_isTransient(e) && attempt < transientRetries) continue;
        if (e is DownloadException) rethrow;
        throw DownloadException('getMessages failed: ${e.runtimeType}',
            stage: 'getMessages', code: '${e.runtimeType}');
      }
    }
  }

  static bool _isTransient(Object e) =>
      e is TimeoutException || e is SocketException || e is SocketDeadException;

  static t.InputDocumentFileLocation _locationOf(t.Document doc) =>
      t.InputDocumentFileLocation(
        id: doc.id,
        accessHash: doc.accessHash,
        fileReference: doc.fileReference,
        thumbSize: '',
      );

  /// Fetches [doc]'s bytes as several 1 MB windows in parallel (bounded
  /// concurrency) and writes each to [sink] at [baseOffset] + its offset
  /// within this document. Writes are serialized with a lock since
  /// concurrent `setPosition` + `writeFrom` pairs on the same handle would
  /// otherwise race; the network requests — the actual bottleneck — still run
  /// concurrently. Returns the total bytes written, always `doc.size`: a
  /// window that comes back short fails the download instead of leaving a
  /// hole.
  Future<int> _downloadDocument({
    required t.Document doc,
    required int messageId,
    required int baseOffset,
    required RandomAccessFile sink,
    void Function(int bytesSoFar)? onChunk,
  }) async {
    const concurrency = 4;
    final size = doc.size;
    final ranges = downloadRanges(size, chunkSize: debugChunkSize);
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

    // File references expire: a FILE_REFERENCE_* error re-reads the message
    // for a fresh one. Windows that hit it together share one refresh.
    var location = _locationOf(doc);
    Future<t.InputDocumentFileLocation>? refreshing;
    Future<t.InputDocumentFileLocation> refresh(t.InputDocumentFileLocation stale) {
      if (!identical(location, stale)) return Future.value(location);
      return refreshing ??= _fetchDocumentWithRetry(messageId).then((d) {
        location = _locationOf(d);
        return location;
      }).whenComplete(() => refreshing = null);
    }

    Future<List<int>> fetchWindow(DownloadRange range) async {
      final expected = min(range.limit, size - range.offset);
      var refreshes = 0;
      var retries = 0;
      while (true) {
        final used = location;
        final t.Result<t.UploadFileBase> result;
        try {
          result = await _getFile(used, range.offset, range.limit);
        } catch (e) {
          if (_isTransient(e) && retries < transientRetries) {
            retries++;
            onChunk?.call(completed); // keep-alive: retrying, not stalled
            continue;
          }
          if (e is DownloadException) rethrow;
          throw DownloadException('getFile failed: ${e.runtimeType}',
              stage: 'getFile', code: '${e.runtimeType}');
        }
        final error = result.error;
        if (error != null) {
          final message = error.errorMessage;
          if (message.startsWith('FILE_REFERENCE_') && refreshes < referenceRefreshes) {
            refreshes++;
            await refresh(used);
            onChunk?.call(completed);
            continue;
          }
          throw DownloadException('getFile failed: $message',
              stage: 'getFile', code: safeRpcCode(message));
        }
        final file = result.result;
        if (file is! t.UploadFile) {
          throw DownloadException('Unexpected getFile response type.',
              stage: 'getFile',
              code: file is t.UploadFileCdnRedirect ? 'CDN_REDIRECT' : 'UNEXPECTED_TYPE');
        }
        final bytes = file.bytes;
        // A short or empty window used to be skipped silently, leaving a hole
        // that the length check could not see once later windows were
        // written past it.
        if (bytes.length != expected) {
          throw DownloadException('getFile returned ${bytes.length} of $expected bytes.',
              stage: 'getFile', code: bytes.length < expected ? 'SHORT_READ' : 'LONG_READ');
        }
        return bytes;
      }
    }

    Future<void> worker() async {
      while (failure == null) {
        final i = nextIndex;
        if (i >= ranges.length) return;
        nextIndex++;
        final range = ranges[i];

        try {
          final bytes = await fetchWindow(range);
          if (failure != null) return;

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
  }) {
    // One download per file at a time: the viewer's neighbour pages and the
    // precacher can ask for the same photo at once, and each used to start its
    // own 4-window download of it. Kept here on the calling isolate, so the
    // worker never receives two requests for one file. Later callers wait on
    // the first and receive its progress too (see [_joinShared]) — a viewer
    // page joined to the prefetcher's download, or retrying after its own
    // timeout, must see the shared download advance or it times out again.
    //
    // The entry is removed when the future completes with a value or an error,
    // and every path below completes: the worker request fails with
    // DownloadException('timeout') after DownloadWorker.transferInactivityTimeout
    // without progress, the inline path is guarded the same way, so a dead
    // connection can't leave a stale future here that every later caller joins.
    return _joinShared(_inFlightCache, item.id, onProgress,
        (report) => _downloadToCache(item, onProgress: report));
  }

  final Map<String, _SharedDownload> _inFlightCache = {};

  /// Same per-file dedupe for [downloadIntoCache], on the isolate that does
  /// the download (the worker). After a request timed out on the main side
  /// the worker's download keeps running; a retry joins it here instead of
  /// starting a second copy of the same file.
  final Map<String, _SharedDownload> _inFlightIntoCache = {};

  /// Joins the download of [id] in [map], or starts one with [start] (handed
  /// the progress fan-out). Every caller's [onProgress] receives the shared
  /// progress from the moment it joins (the last value first).
  static Future<File> _joinShared(
    Map<String, _SharedDownload> map,
    String id,
    void Function(double progress)? onProgress,
    Future<File> Function(void Function(double progress) report) start,
  ) {
    var entry = map[id];
    final isNew = entry == null;
    entry ??= map[id] = _SharedDownload();
    final shared = entry;
    if (onProgress != null) {
      if (!isNew && shared.last > 0) onProgress(shared.last);
      shared.listeners.add(onProgress);
    }
    if (isNew) {
      shared.future = start(shared.report);
      shared.future.whenComplete(() {
        if (identical(map[id], shared)) map.remove(id);
      }).ignore();
    }
    if (onProgress == null) return shared.future;
    return shared.future.whenComplete(() => shared.listeners.remove(onProgress));
  }

  /// The already-available copy of [item] (device original or complete cache
  /// file), or null — never starts a download.
  Future<File?> cachedFileFor(FileItem item) async {
    final linked = BackupRegistry.instance.localPathFor(item.id);
    if (linked != null) {
      final local = File(linked);
      if (await local.exists()) return local;
    }
    final tmp = await getTemporaryDirectory();
    final cached = File(p.join(tmp.path, 'televault_cache', item.id, item.name));
    if (await cached.exists() && await cached.length() == item.totalSize) return cached;
    return null;
  }

  Future<File> _downloadToCache(
    FileItem item, {
    void Function(double progress)? onProgress,
  }) async {
    // Checked here, not in the worker: the device-original link lives in
    // BackupRegistry, which only this isolate has loaded and keeps current.
    final ready = await cachedFileFor(item);
    if (ready != null) {
      onProgress?.call(1);
      return ready;
    }
    if (DownloadWorker.enabled) {
      return File(
          await DownloadWorker.instance.downloadToCache(item, onProgress: onProgress));
    }
    // Inline (headless engine, desktop): no worker timeout applies here, so
    // guard it the same way. Progress per chunk keeps a healthy download alive.
    return withInactivityTimeout<File>(
      DownloadWorker.transferInactivityTimeout,
      (touch) => downloadIntoCache(item, onProgress: (p) {
        touch();
        onProgress?.call(p);
      }),
    );
  }

  /// Downloads [item] into the preview cache folder
  /// (`<temp>/televault_cache/<id>/<name>`), reusing a complete copy already
  /// there. Always downloads on the current isolate — this is what
  /// [DownloadWorker] runs — and skips the device-original check, since
  /// BackupRegistry isn't loaded on the worker isolate; callers go through
  /// [downloadToCache], which does that check first.
  Future<File> downloadIntoCache(
    FileItem item, {
    void Function(double progress)? onProgress,
  }) async {
    return _joinShared(_inFlightIntoCache, item.id, onProgress, (report) async {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'televault_cache', item.id));
      await dir.create(recursive: true);
      final cached = File(p.join(dir.path, item.name));

      if (await cached.exists() && await cached.length() == item.totalSize) {
        report(1);
        return cached;
      }
      return _downloadFile(item, destDir: dir.path, onProgress: report);
    });
  }

  /// Fetches the [t.Document] backing a stored part by its message id. The
  /// file reference is read fresh here because Telegram references expire.
  /// Public so the thumbnail service can read a video's embedded thumbnail.
  Future<t.Document> fetchDocument(int messageId) async {
    final result = await TelegramService.instance.call(
      (c) => c.messages.getMessages(id: [t.InputMessageID(id: messageId)]),
    );
    if (result.error != null) {
      final message = result.error!.errorMessage;
      throw DownloadException('getMessages failed: $message',
          stage: 'getMessages', code: safeRpcCode(message));
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
    throw DownloadException('No document found in message $messageId.',
        stage: 'getMessages', code: 'NO_DOCUMENT');
  }
}

/// One in-flight download shared by every caller that asked for the same file
/// (see [DownloadService._joinShared]).
class _SharedDownload {
  late final Future<File> future;
  final List<void Function(double progress)> listeners = [];
  double last = 0;

  void report(double progress) {
    last = progress;
    for (final l in List.of(listeners)) {
      l(progress);
    }
  }
}

class DownloadException implements Exception {
  final String message;

  /// Where it failed (`getMessages`, `getFile`, `inactivity`, `worker`, ...).
  final String? stage;

  /// Safe reason code: a Telegram RPC error name (FILE_REFERENCE_EXPIRED), an
  /// exception class name, or one of this module's own codes (SHORT_READ,
  /// TIMEOUT, ...). Never a file name, path or caption.
  final String? code;

  /// Which part of a multi-part file, as `n/total`.
  final String? part;

  DownloadException(this.message, {this.stage, this.code, this.part});

  DownloadException withPart(String part) =>
      DownloadException(message, stage: stage, code: code, part: part);

  /// `stage=getFile code=FILE_REFERENCE_EXPIRED part=2/3` — safe to log.
  String get reason =>
      'stage=${stage ?? '-'} code=${code ?? '-'}${part == null ? '' : ' part=$part'}';

  @override
  String toString() => 'DownloadException: $message';
}

/// [message] when it looks like a Telegram RPC error name (FLOOD_WAIT_5,
/// FILE_REFERENCE_EXPIRED), otherwise `RPC_ERROR` — so the code can be logged
/// whatever the server sent.
String safeRpcCode(String message) =>
    RegExp(r'^[A-Z0-9_]{1,64}$').hasMatch(message) ? message : 'RPC_ERROR';

/// A safe one-line reason for [e] (see [DownloadException.reason]); never
/// includes the exception's text, only codes and class names.
String downloadFailureReason(Object e, {String? part}) {
  if (e is DownloadException) {
    return (e.part == null && part != null ? e.withPart(part) : e).reason;
  }
  final code = e is FloodWaitException ? 'FLOOD_WAIT_${e.seconds}' : '${e.runtimeType}';
  return 'stage=- code=$code${part == null ? '' : ' part=$part'}';
}
