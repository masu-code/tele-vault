import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pool/pool.dart';
import 'package:t/t.dart' as t;
import '../../models/file_item.dart';
import '../download/download_service.dart';
import '../telegram/client.dart';

/// Top-level so it can run in an isolate via [compute]: decode, downscale to a
/// 256px-wide JPEG thumbnail. Returns the original bytes if decoding fails.
Uint8List _resizeToThumbnail(Uint8List src) {
  final decoded = img.decodeImage(src);
  if (decoded == null) return src;
  final resized = img.copyResize(decoded, width: 256);
  return Uint8List.fromList(img.encodeJpg(resized, quality: 80));
}

/// Produces small preview thumbnails for the gallery and lists, built to scale
/// to thousands of files without hanging or running out of memory:
///
/// - **Persistent disk cache**: a generated thumbnail (~KB) is written under
///   the app support dir and reused across sessions — fetched/generated once.
/// - **Concurrency limit**: at most [_maxConcurrent] thumbnails are
///   fetched/generated at a time (a [Pool]), so a screen full of tiles can't
///   flood Telegram with requests and stall.
/// - **Lightweight source**: prefers Telegram's server thumbnail (a few KB, no
///   full download). For images lacking one, downloads once and downscales to
///   256px off the UI thread. Videos without a server thumbnail show a
///   placeholder (downloading a whole video for a thumbnail would not scale).
/// - **Cancellation**: tiles scrolled out of view can [cancel] their pending
///   job so it releases its queue slot.
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  static const int _maxConcurrent = 4;
  static const Duration _netTimeout = Duration(seconds: 30);

  final Pool _pool = Pool(_maxConcurrent);
  final Map<String, File?> _mem = {};
  final Map<String, Future<File?>> _inflight = {};
  final Set<String> _cancelled = {};

  Directory? _dir;

  /// Marks a thumbnail job as cancellable; a not-yet-started job will be
  /// skipped. Called when a tile leaves the viewport.
  void cancel(String fileId) => _cancelled.add(fileId);

  Future<Directory> _thumbDir() async {
    if (_dir != null) return _dir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'televault_thumbs'));
    await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Returns a thumbnail file for [file], or null if none can be produced.
  Future<File?> thumbnailFor(FileItem file) async {
    _cancelled.remove(file.id); // requesting again clears any prior cancel
    if (_mem.containsKey(file.id)) return _mem[file.id];

    final dir = await _thumbDir();
    final onDisk = File(p.join(dir.path, '${file.id}.jpg'));
    if (await onDisk.exists()) {
      _mem[file.id] = onDisk;
      return onDisk;
    }

    return _inflight.putIfAbsent(file.id, () async {
      try {
        if (_cancelled.contains(file.id)) return null;
        final result = await _pool.withResource(() => _generate(file, onDisk));
        _mem[file.id] = result;
        return result;
      } catch (_) {
        return null;
      } finally {
        _inflight.remove(file.id);
      }
    });
  }

  Future<File?> _generate(FileItem file, File onDisk) async {
    if (_cancelled.contains(file.id)) return null;

    final isImage = file.mimeType.startsWith('image/');
    final isVideo = file.mimeType.startsWith('video/');
    if (!isImage && !isVideo) return null;

    // 1) Prefer Telegram's server thumbnail (small, no full download).
    Uint8List? bytes = await _telegramThumbBytes(file);

    // 2) For images without one, download once and downscale off-thread.
    if (bytes == null && isImage) {
      final full = await DownloadService.instance.downloadToCache(file);
      final src = await full.readAsBytes();
      bytes = await compute(_resizeToThumbnail, src);
    }

    if (bytes == null) return null;
    await onDisk.writeAsBytes(bytes);
    return onDisk;
  }

  /// Fetches Telegram's embedded thumbnail (a PhotoSize) for the file's first
  /// part, or null when none exists.
  Future<Uint8List?> _telegramThumbBytes(FileItem file) async {
    final ordered = [...file.parts]..sort((a, b) => a.part.compareTo(b.part));
    final doc = await DownloadService.instance
        .fetchDocument(ordered.first.messageId)
        .timeout(_netTimeout);

    final thumbs = doc.thumbs;
    if (thumbs == null || thumbs.isEmpty) return null;

    t.PhotoSize? best;
    for (final th in thumbs) {
      if (th is t.PhotoSize && (best == null || th.size < best.size)) best = th;
    }
    if (best == null) return null;
    final bestThumb = best; // non-nullable alias — analyzer loses null-safety across lambdas

    final result = await TelegramService.instance.call((c) => c.upload.getFile(
      precise: false,
      cdnSupported: false,
      location: t.InputDocumentFileLocation(
        id: doc.id,
        accessHash: doc.accessHash,
        fileReference: doc.fileReference,
        thumbSize: bestThumb.type,
      ),
      offset: 0,
      limit: 1024 * 1024,
    ));

    final uploaded = result.result;
    return uploaded is t.UploadFile ? uploaded.bytes : null;
  }
}
