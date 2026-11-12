import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:t/t.dart' as t;
import '../../models/file_item.dart';
import '../download/download_service.dart';
import '../telegram/client.dart';
import 'server_thumb_batch.dart';
import 'thumb_prefetcher.dart';
import 'thumb_store.dart';

export 'thumb_encoder.dart' show resizeToThumbnail;

/// The thumbnail API the viewer, the explorer and the album covers use. It is
/// a thin facade: the files live in [ThumbStore], and everything that has to
/// be fetched or generated is scheduled by [ThumbPrefetcher] (device asset,
/// pack, server thumbnail, then full download; see its docs).
///
/// Nothing here caches a failure: a null result means "not available right
/// now", and asking again retries (subject to the prefetcher's backoff).
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  static const Duration _netTimeout = Duration(seconds: 30);

  /// Thumbnails of device assets read back for the viewer, newest last. Small
  /// on purpose: each entry is a ~20 KB JPEG and the viewer only asks for the
  /// photo being opened and its neighbours.
  static const int _localMemCap = 64;
  final Map<String, Uint8List> _localMem = {};

  ThumbStore get _store => ThumbStore.instance;
  ThumbPrefetcher get _prefetcher => ThumbPrefetcher.instance;

  /// Marks a request as no longer wanted. Keyed by the id the request was made
  /// with (a cloud file id or a device asset id). Called when a tile leaves
  /// the viewport.
  void cancel(String id) => _prefetcher.cancel(id);

  /// The stored thumbnail file for cloud item [fileId], or null.
  File? cachedCloud(String fileId) => _store.fileIfPresent(fileId);

  /// The thumbnail bytes for device asset [assetId], or null when none is
  /// stored yet. Synchronous (a ~20 KB read): lets the viewer paint the grid
  /// thumbnail in its first frame.
  Uint8List? cachedLocal(String assetId) {
    final mem = _localMem[assetId];
    if (mem != null) return mem;
    final key = _prefetcher.keyForAsset(assetId);
    if (key == null) return null;
    final file = _store.fileIfPresent(key);
    if (file == null) return null;
    try {
      final bytes = file.readAsBytesSync();
      _rememberLocal(assetId, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _rememberLocal(String id, Uint8List bytes) {
    _localMem.remove(id); // re-insert so it counts as most-recently used
    _localMem[id] = bytes;
    while (_localMem.length > _localMemCap) {
      _localMem.remove(_localMem.keys.first);
    }
  }

  /// Returns a thumbnail file for [file], or null if none can be produced right
  /// now. Hits the store first; otherwise a prioritized request is awaited
  /// once.
  Future<File?> thumbnailFor(FileItem file) async {
    if (!await _storeReady()) return null;
    final hit = _store.fileIfPresent(file.id);
    if (hit != null) return hit;
    return _prefetcher.fetch(ThumbRequest(key: file.id, file: file));
  }

  /// Returns the thumbnail bytes for a device [asset] (read back from the
  /// store), generating it first when it is not stored yet.
  Future<Uint8List?> localThumbnailFor(AssetEntity asset) async {
    final cached = cachedLocal(asset.id);
    if (cached != null) return cached;
    if (!await _storeReady()) return null;
    final key = _prefetcher.keyForAsset(asset.id) ??
        ThumbKey.forEntry(assetId: asset.id, assetModifiedSec: asset.modifiedDateSecond);
    var file = _store.fileIfPresent(key);
    file ??= await _prefetcher.fetch(ThumbRequest(key: key, assetId: asset.id, asset: asset));
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      _rememberLocal(asset.id, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _storeReady() async {
    if (_store.isReady) return true;
    try {
      await _store.init();
      return _store.isReady;
    } catch (_) {
      return false; // no path_provider (widget tests): degrade to "no thumbnail"
    }
  }

  /// Fetches Telegram's embedded thumbnail (the largest PhotoSize of at most
  /// 320 px) for the file's first part, or null when none exists. Always runs
  /// on the current isolate — this is what `DownloadWorker`'s `thumb` request
  /// calls.
  Future<Uint8List?> serverThumbnailBytes(FileItem file) async {
    final ordered = [...file.parts]..sort((a, b) => a.part.compareTo(b.part));
    final doc = await DownloadService.instance
        .fetchDocument(ordered.first.messageId)
        .timeout(_netTimeout);

    final best = pickServerThumb(doc.thumbs);
    if (best == null) return null;

    final result = await TelegramService.instance.call(
      (c) => c.upload.getFile(
        precise: false,
        cdnSupported: false,
        location: t.InputDocumentFileLocation(
          id: doc.id,
          accessHash: doc.accessHash,
          fileReference: doc.fileReference,
          thumbSize: best.type,
        ),
        offset: 0,
        limit: 1024 * 1024,
      ),
    );

    final uploaded = result.result;
    return uploaded is t.UploadFile ? uploaded.bytes : null;
  }
}
