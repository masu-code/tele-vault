import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
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

  // Separate pool for device-asset thumbnails: a platform-channel + native
  // decode call, not a network fetch, so it doesn't compete with Telegram's
  // 4 download slots above — a faster local resource gets its own budget.
  static const int _maxConcurrentLocal = 6;
  final Pool _localPool = Pool(_maxConcurrentLocal);
  final Map<String, Uint8List> _localMem = {};
  final Map<String, Future<Uint8List?>> _localInflight = {};

  /// Cap on decoded device thumbnails held in memory. Without a bound this
  /// grew one entry per asset ever scrolled past — thousands of buffers on a
  /// large library. Evicts oldest-first (plain insertion order).
  static const int _localMemCap = 400;

  Directory? _dir;

  /// Marks a request as cancelled so it can be skipped. Keyed by the same id
  /// the request was made with (a cloud file id or a device asset id).
  /// Called when a tile leaves the viewport.
  void cancel(String id) => _cancelled.add(id);

  /// The already-in-memory thumbnail for [fileId]/[assetId], or null. Lets a
  /// tile paint instantly when scrolling back over content it already loaded,
  /// instead of going through the request path again for something in hand.
  File? cachedCloud(String fileId) => _mem[fileId];
  Uint8List? cachedLocal(String assetId) => _localMem[assetId];

  void _rememberLocal(String id, Uint8List bytes) {
    _localMem.remove(id); // re-insert so it counts as most-recently used
    _localMem[id] = bytes;
    while (_localMem.length > _localMemCap) {
      _localMem.remove(_localMem.keys.first);
    }
  }

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
        // A null from a cancelled job means "didn't run", not "has no
        // thumbnail" — caching that would leave the tile blank for good.
        // A null from a job that did run (e.g. a video with no server
        // thumbnail) is worth caching so it isn't retried every time.
        if (!_cancelled.contains(file.id)) _mem[file.id] = result;
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

  /// Returns thumbnail bytes for a device [asset], cached in memory and
  /// deduped/pooled the same way as [thumbnailFor] — the Gallery timeline is
  /// now mostly device photos, and without this every tile scrolling into
  /// view called photo_manager directly with no cache and no concurrency
  /// limit at all.
  Future<Uint8List?> localThumbnailFor(AssetEntity asset) async {
    _cancelled.remove(asset.id); // requesting again clears any prior cancel
    final cached = _localMem[asset.id];
    if (cached != null) return cached;

    return _localInflight.putIfAbsent(asset.id, () async {
      try {
        final bytes = await _localPool.withResource(() {
          // Checked HERE — inside the pool callback — and not just before
          // queueing. withResource() runs this only once a slot frees up,
          // which during a fast fling is long after the tile that asked for
          // it was destroyed. Without this check those dead requests still
          // ran, so the 6 slots stayed full of work for rows the user had
          // already scrolled past and nothing on screen could load until the
          // whole backlog drained — i.e. until scrolling fully stopped.
          if (_cancelled.contains(asset.id)) return null;
          return asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));
        });
        // Deliberately not caching a null: it means "cancelled" or "failed",
        // and caching it would make the tile permanently blank on scroll-back.
        if (bytes != null) _rememberLocal(asset.id, bytes);
        return bytes;
      } catch (_) {
        return null;
      } finally {
        _localInflight.remove(asset.id);
      }
    });
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
