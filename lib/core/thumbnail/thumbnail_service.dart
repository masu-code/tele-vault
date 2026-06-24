import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:t/t.dart' as t;
import '../../models/file_item.dart';
import '../download/download_service.dart';
import '../telegram/client.dart';

/// Produces small preview thumbnails for the file list.
///
/// - Images: the image itself is downloaded to cache and shown scaled down.
/// - Videos: Telegram's server-generated thumbnail (the Document's embedded
///   PhotoSize) is fetched — a few KB — without downloading the whole video.
///   If Telegram produced no thumbnail, returns null and the list shows a
///   generic icon.
///
/// Results are cached in memory (per file id) and on disk, and concurrent
/// requests for the same file are de-duplicated.
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  final Map<String, File?> _cache = {};
  final Map<String, Future<File?>> _inflight = {};

  t.Client get _client => TelegramService.instance.client;

  /// Returns a thumbnail file for [file], or null if none can be produced.
  Future<File?> thumbnailFor(FileItem file) {
    if (_cache.containsKey(file.id)) return Future.value(_cache[file.id]);
    return _inflight.putIfAbsent(file.id, () async {
      File? result;
      try {
        if (file.mimeType.startsWith('image/')) {
          result = await DownloadService.instance.downloadToCache(file);
        } else if (file.mimeType.startsWith('video/')) {
          result = await _videoThumbnail(file);
        }
      } catch (_) {
        result = null;
      }
      _cache[file.id] = result;
      _inflight.remove(file.id);
      return result;
    });
  }

  Future<File?> _videoThumbnail(FileItem file) async {
    final ordered = [...file.parts]..sort((a, b) => a.part.compareTo(b.part));
    final doc = await DownloadService.instance.fetchDocument(ordered.first.messageId);

    final thumbs = doc.thumbs;
    if (thumbs == null || thumbs.isEmpty) return null;

    // Prefer a downloadable PhotoSize (skip inline stripped/cached variants).
    t.PhotoSize? best;
    for (final th in thumbs) {
      if (th is t.PhotoSize) {
        if (best == null || th.size < best.size) best = th;
      }
    }
    if (best == null) return null;

    final location = t.InputDocumentFileLocation(
      id: doc.id,
      accessHash: doc.accessHash,
      fileReference: doc.fileReference,
      thumbSize: best.type,
    );
    final result = await _client.upload.getFile(
      precise: false,
      cdnSupported: false,
      location: location,
      offset: 0,
      limit: 1024 * 1024,
    );
    final uploaded = result.result;
    if (uploaded is! t.UploadFile) return null;

    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'televault_cache', file.id));
    await dir.create(recursive: true);
    final out = File(p.join(dir.path, 'thumb.jpg'));
    await out.writeAsBytes(uploaded.bytes);
    return out;
  }
}
