import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:t/t.dart' as t;
import 'package:tv_core/codecs.dart' show PreviewCodec;
import 'package:uuid/uuid.dart';
import '../../models/capture_date.dart';
import '../../models/file_index.dart';
import '../../models/file_item.dart';
import '../../models/file_part.dart';
import '../backup/registry_store.dart' show PendingIndexRow;
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import '../thumbnail/preview_table.dart';
import '../thumbnail/thumb_store.dart';
import 'upload_plan.dart';

const _uuid = Uuid();

/// An error rendered for logs and stored statuses: never a file name or path.
/// A [FileSystemException] (which embeds the path) is reduced to its type and
/// OS error code; anything else keeps its message (Telegram RPC errors such as
/// AUTH_KEY_UNREGISTERED must stay recognizable).
String logSafeError(Object e) {
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    return '${e.runtimeType}${code == null ? '' : '(os $code)'}';
  }
  return e.toString();
}

/// After a successful upload: stores [thumbJpeg] as the cloud thumbnail of
/// [fileItemId] and its ThumbHash [previewHash] in the preview table, so the
/// gallery tile has both without fetching anything. Never throws.
Future<void> rememberUploadedThumb(
  String fileItemId, {
  Uint8List? thumbJpeg,
  Uint8List? previewHash,
}) async {
  try {
    if (previewHash != null) PreviewTable.instance.put(fileItemId, previewHash);
    if (thumbJpeg != null) await ThumbStore.instance.put(fileItemId, thumbJpeg);
  } catch (_) {
    // Best effort: the prefetcher fetches the server thumb later.
  }
}

/// One upload that finished and waits for its index write.
typedef FinishedUpload = ({FileItem item, String assetId, String path});

/// One registry link written by a flush (see `BackupRegistry.commitUploads`).
typedef UploadLink = ({String assetId, String fileItemId, String path});

/// Records a flushed batch in the registry once [written] (the index the save
/// actually wrote, rebased onto other writers) is known.
///
/// * An upload whose item is in [written] links to it.
/// * An upload dropped by the rebase as a duplicate ([droppedIds], or simply
///   absent from [written]) links to the surviving file with the same name
///   and size, the same rule as the dedupe before an upload; with none, it is
///   not linked and the next pass checks it again.
/// * [alreadyInVault] links (dedupe hits) are written as given.
///
/// Every link goes in ONE [commitUploads] call (one transaction); each dropped
/// id is then passed to [unlinkFileItem] so no registry entry points at an id
/// the index does not hold. Returns the links written.
Future<List<UploadLink>> commitFlushedUploads({
  required FileIndex written,
  required List<FinishedUpload> uploaded,
  List<UploadLink> alreadyInVault = const [],
  List<String> droppedIds = const [],
  required Future<void> Function(List<UploadLink> links) commitUploads,
  required Future<void> Function(String fileItemId) unlinkFileItem,
}) async {
  final present = <String>{for (final f in written.files) f.id};
  final dropped = droppedIds.toSet();
  final links = <UploadLink>[...alreadyInVault];
  for (final u in uploaded) {
    if (present.contains(u.item.id) && !dropped.contains(u.item.id)) {
      links.add((assetId: u.assetId, fileItemId: u.item.id, path: u.path));
      continue;
    }
    final survivor = written.findUpload(u.item.name, u.item.totalSize);
    if (survivor != null && !dropped.contains(survivor.id)) {
      links.add((assetId: u.assetId, fileItemId: survivor.id, path: u.path));
    }
  }
  if (links.isNotEmpty) await commitUploads(links);
  for (final id in dropped) {
    await unlinkFileItem(id);
  }
  return links;
}

/// The [FinishedUpload] a pending-index row stands for; null when its stored
/// item cannot be decoded.
FinishedUpload? finishedUploadFromRow(PendingIndexRow row) {
  try {
    final item = FileItem.fromJson(jsonDecode(row.itemJson) as Map<String, dynamic>);
    return (item: item, assetId: row.assetId, path: row.path);
  } catch (_) {
    return null;
  }
}

/// The JSON a pending-index row stores for [item].
String pendingItemJson(FileItem item) => jsonEncode(item.toJson());

/// How [indexPendingUploads] writes the index: applies `addMissing` to the
/// index current at its turn (the notifier's write chain, or a fresh load),
/// saves it unless `addMissing` returned it unchanged, and returns the index
/// written plus the ids the rebase dropped as duplicates. Throws when the
/// save fails.
typedef PendingIndexSave = Future<({FileIndex index, List<String> dropped})> Function(
  FileIndex Function(FileIndex current) addMissing,
);

/// Result of [indexPendingUploads]: the index written, the registry links
/// committed, and the file item ids no longer pending.
typedef PendingIndexResult = ({
  FileIndex written,
  List<UploadLink> links,
  List<String> settled,
});

/// Writes [uploads] (files already on Telegram, persisted as pending-index
/// rows) to the index, then links them and clears their rows.
///
/// Only the uploads missing from the index current at the save's turn are
/// added, so a retry after a write that did land (or a crash between the
/// link commit and the row removal) adds nothing twice. The registry links
/// come from the index [save] returns ([commitFlushedUploads]); an upload is
/// [removePending]'d only once it is linked, i.e. its item (or the surviving
/// duplicate) is in that index. When [save] throws, nothing is linked or
/// removed and the error propagates: the rows stay for the next attempt.
Future<PendingIndexResult> indexPendingUploads({
  required List<FinishedUpload> uploads,
  List<UploadLink> alreadyInVault = const [],
  required PendingIndexSave save,
  required Future<void> Function(List<UploadLink> links) commitUploads,
  required Future<void> Function(String fileItemId) unlinkFileItem,
  required Future<void> Function(List<String> fileItemIds) removePending,
}) async {
  final seen = <String>{};
  final unique = [
    for (final u in uploads)
      if (seen.add(u.item.id)) u,
  ];
  if (unique.isEmpty) {
    final links = await commitFlushedUploads(
      written: FileIndex.empty(),
      uploaded: const [],
      alreadyInVault: alreadyInVault,
      commitUploads: commitUploads,
      unlinkFileItem: unlinkFileItem,
    );
    return (written: FileIndex.empty(), links: links, settled: const <String>[]);
  }

  FileIndex addMissing(FileIndex current) {
    final have = {for (final f in current.files) f.id};
    final missing = [
      for (final u in unique)
        if (!have.contains(u.item.id)) u.item,
    ];
    return missing.isEmpty ? current : current.addFiles(missing);
  }

  final saved = await save(addMissing);
  final links = await commitFlushedUploads(
    written: saved.index,
    uploaded: unique,
    alreadyInVault: alreadyInVault,
    droppedIds: saved.dropped,
    commitUploads: commitUploads,
    unlinkFileItem: unlinkFileItem,
  );
  // commitFlushedUploads puts the given hits first, then one link per
  // upload it could place in the written index.
  final linkedAssets = {
    for (final l in links.skip(alreadyInVault.length)) l.assetId,
  };
  final settled = [
    for (final u in unique)
      if (linkedAssets.contains(u.assetId)) u.item.id,
  ];
  await removePending(settled);
  return (written: saved.index, links: links, settled: settled);
}

/// When device [asset] was taken, as epoch ms for [UploadService.uploadFile]'s
/// `takenAtMs` (the date the gallery shows it under once only the cloud copy
/// is left); null when neither the device nor the file name gives a
/// believable date (see [deviceCaptureMs]).
int? assetTakenAtMs(AssetEntity asset) => deviceCaptureMs(asset);

/// Telegram's limits for the preview attached to a document: JPEG, at most
/// 200 KB, neither side over 320 px. Anything outside them is dropped rather
/// than sent — a rejected thumb would otherwise cost the whole upload.
const _maxThumbBytes = 200 * 1024;
const _maxThumbSide = 320;

/// Builds the small JPEG preview attached to [asset]'s upload, using the
/// platform's own thumbnailer (works for photos and videos alike).
///
/// Deriving it once here, from the original still on the device, is what
/// lets the gallery show cloud-only files later without downloading and
/// decoding the full photo/video. Returns null — never throws — when no
/// usable preview can be made; the upload then just goes without one.
Future<Uint8List?> uploadThumbFor(AssetEntity asset) async {
  try {
    // Ask for a box with the asset's own aspect ratio and its longest side at
    // the limit. Android's thumbnailer (Glide) scales to *cover* the box, so
    // a square 320x320 request would come back 427 px long for a 4:3 photo.
    var box = _fitBox(asset.orientatedWidth, asset.orientatedHeight);
    // A second attempt covers dimensions MediaStore reports pre-rotation (or
    // not at all): shrink the box by however much the first result overshot.
    for (var attempt = 0; attempt < 2; attempt++) {
      final bytes = await asset.thumbnailDataWithSize(
        ThumbnailSize(box.w, box.h),
        format: ThumbnailFormat.jpeg,
        quality: 80,
      );
      if (bytes == null || bytes.length > _maxThumbBytes) return null;
      final size = _jpegSize(bytes);
      if (size == null) return null;
      final longest = math.max(size.w, size.h);
      if (longest <= _maxThumbSide) return bytes;
      box = (
        w: math.max(1, box.w * _maxThumbSide ~/ longest),
        h: math.max(1, box.h * _maxThumbSide ~/ longest),
      );
    }
  } catch (e) {
    // ignore: avoid_print
    print('TVDIAG: thumbnail for ${asset.id} failed, uploading without: '
        '${logSafeError(e)}');
  }
  return null;
}

/// The thumbnail request box for a [w]x[h] asset: longest side at the limit,
/// shorter side rounded *down* so the cover-scaling never pushes the longest
/// side past it. Unknown dimensions fall back to a square.
({int w, int h}) _fitBox(int w, int h) {
  if (w <= 0 || h <= 0) return (w: _maxThumbSide, h: _maxThumbSide);
  return w >= h
      ? (w: _maxThumbSide, h: math.max(1, h * _maxThumbSide ~/ w))
      : (w: math.max(1, w * _maxThumbSide ~/ h), h: _maxThumbSide);
}

/// Reads a JPEG's pixel dimensions from its SOF header, or null if [bytes]
/// isn't a JPEG this can parse.
({int w, int h})? _jpegSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    // SOF0..SOF15, minus DHT (C4), JPG (C8) and DAC (CC), which share the range.
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      final h = (bytes[i + 5] << 8) | bytes[i + 6];
      final w = (bytes[i + 7] << 8) | bytes[i + 8];
      return (w: w, h: h);
    }
    i += 2 + ((bytes[i + 2] << 8) | bytes[i + 3]);
  }
  return null;
}

bool _isValidThumb(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > _maxThumbBytes) return false;
  final size = _jpegSize(bytes);
  return size != null &&
      size.w > 0 &&
      size.h > 0 &&
      math.max(size.w, size.h) <= _maxThumbSide;
}

/// Sends one segment as a Telegram document and returns its message id — the
/// shape of [UploadService]'s own segment upload (replaceable in tests).
typedef SegmentSender = Future<int> Function(
  RandomAccessFile raf,
  UploadSegment seg,
  String name,
  String mime,
  int totalSegments,
  void Function(int chunkBytes) onChunk, {
  Uint8List? thumbJpeg,
});

/// Uploads local files to Telegram and produces the [FileItem] to record in the
/// index. Large files are split into multiple documents (segments) that are
/// reassembled on download; each segment is uploaded in 512 KB parts.
///
/// Files currently land in the user's Saved Messages (InputPeerSelf). A future
/// phase can move storage to a dedicated private channel without changing the
/// public surface of this service.
class UploadService {
  UploadService._() : _segmentSender = null;
  static final UploadService instance = UploadService._();

  /// A service whose segments go to [sendSegment] instead of Telegram (tests).
  @visibleForTesting
  UploadService.forTesting(SegmentSender sendSegment) : _segmentSender = sendSegment;

  final SegmentSender? _segmentSender;

  /// Parts of one file in flight at once — see [_uploadSegment].
  static const int _parallelParts = 4;

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
  /// [thumbJpeg] (see [uploadThumbFor]) is attached to the Telegram document
  /// as its preview. It is strictly optional: one outside Telegram's limits
  /// is ignored, and any failure sending it falls back to uploading without
  /// it — a missing preview must never cost the file itself.
  ///
  /// [preview] is the file's `th1:` ThumbHash string (see `PreviewCodec`),
  /// computed by the caller from the same thumb; it is stored in the returned
  /// [FileItem.preview]. An invalid string is dropped.
  ///
  /// [takenAtMs] is when the photo/video was taken (see [assetTakenAtMs]);
  /// stored in the item's optional [takenAtKey] so the gallery files a
  /// cloud-only copy under its capture month, not its upload month.
  ///
  /// [maxSegmentSizeOverride] exists only so integration tests can force a
  /// small file through the multi-segment (>2GB-file) path without actually
  /// uploading gigabytes of data; production code must never pass it.
  Future<FileItem> uploadFile(
    File file, {
    String? folderId,
    void Function(double progress)? onProgress,
    Uint8List? thumbJpeg,
    String? preview,
    int? takenAtMs,
    int? maxSegmentSizeOverride,
  }) =>
      _serialized(() => _uploadFile(
            file,
            folderId: folderId,
            onProgress: onProgress,
            thumbJpeg: thumbJpeg,
            preview: preview,
            takenAtMs: takenAtMs,
            maxSegmentSizeOverride: maxSegmentSizeOverride,
          ));

  Future<FileItem> _uploadFile(
    File file, {
    String? folderId,
    void Function(double progress)? onProgress,
    Uint8List? thumbJpeg,
    String? preview,
    int? takenAtMs,
    int? maxSegmentSizeOverride,
  }) async {
    final totalSize = await file.length();
    if (totalSize == 0) {
      throw UploadException('Cannot upload an empty file.');
    }
    final thumb = thumbJpeg != null && _isValidThumb(thumbJpeg) ? thumbJpeg : null;
    final validPreview =
        preview != null && PreviewCodec.fromWire(preview) != null ? preview : null;
    final sendSegment = _segmentSender ?? _uploadSegment;

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
          messageId = await sendSegment(
            raf,
            seg,
            name,
            mime,
            segments.length,
            (chunkBytes) {
              uploadedBytes += chunkBytes;
              onProgress?.call(uploadedBytes / totalSize);
            },
            // Only the first document carries the preview: one per file is
            // enough, and the later segments are just raw byte ranges.
            thumbJpeg: seg.index == 0 ? thumb : null,
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
      preview: validPreview,
      extra: takenAtExtra(takenAtMs),
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
    void Function(int chunkBytes) onChunk, {
    Uint8List? thumbJpeg,
  }) async {
    final fileId = randomInt64();
    final totalParts = seg.chunkCount();
    final isBig = seg.isBig;

    // Parts go up [_parallelParts] at a time instead of one-by-one: each
    // saveFilePart round trip to Telegram took ~1.4 s from the user's network,
    // and with a single part in flight that latency — not bandwidth or CPU —
    // capped uploads at ~0.36 MB/s (a 700 MB video took over half an hour).
    // Telegram accepts a file's parts in any order; official clients upload
    // them concurrently the same way. Disk reads are serialized because all
    // workers share one RandomAccessFile position.
    var nextPart = 0;
    var sent = 0;
    Object? failure;
    var readLock = Future<void>.value();
    final segStart = DateTime.now();
    // ignore: avoid_print
    print('TVDIAG: _uploadSegment starting, size=${seg.size}, totalParts=$totalParts, isBig=$isBig');

    Future<Uint8List> readPart(int index) async {
      final prior = readLock;
      final done = Completer<void>();
      readLock = done.future;
      await prior;
      try {
        final start = index * UploadLimits.chunkSize;
        final left = seg.size - start;
        await raf.setPosition(seg.offset + start);
        return await raf.read(left < UploadLimits.chunkSize ? left : UploadLimits.chunkSize);
      } finally {
        done.complete();
      }
    }

    Future<void> worker() async {
      while (failure == null) {
        final partIndex = nextPart;
        if (partIndex >= totalParts) return;
        nextPart++;
        try {
          final bytes = await readPart(partIndex);
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
          sent++;
          if (sent % 20 == 0) {
            // ignore: avoid_print
            print('TVDIAG: $sent/$totalParts parts sent (elapsed ${DateTime.now().difference(segStart).inSeconds}s)');
          }
          onChunk(bytes.length);
        } catch (e) {
          // First failure stops every worker; the caller deletes any
          // already-sent segments and the whole file is retried later.
          failure ??= e;
          return;
        }
      }
    }

    await Future.wait(List.generate(_parallelParts, (_) => worker()));
    final failed = failure;
    if (failed != null) throw failed;
    // ignore: avoid_print
    print('TVDIAG: _uploadSegment all $totalParts parts done in ${DateTime.now().difference(segStart).inSeconds}s, sending final message...');

    // For a multi-segment file, tag each document so it is recognizable in the
    // chat; the user-facing name stays the original in the index.
    final segName = totalSegments > 1 ? '$name.part${seg.index}' : name;

    final thumbFile = thumbJpeg == null ? null : await _uploadThumb(thumbJpeg);

    t.InputMediaUploadedDocument media(t.InputFileBase? thumb) =>
        t.InputMediaUploadedDocument(
          nosoundVideo: false,
          forceFile: true,
          spoiler: false,
          file: isBig
              ? t.InputFileBig(id: fileId, parts: totalParts, name: segName)
              : t.InputFile(id: fileId, parts: totalParts, name: segName, md5Checksum: ''),
          thumb: thumb,
          mimeType: mime,
          attributes: [t.DocumentAttributeFilename(fileName: segName)],
        );

    var randomId = randomInt64();
    Future<t.Result<t.UpdatesBase>> send(t.InputFileBase? thumb) =>
        withAuthKeyRetry(() => TelegramService.instance.call((c) => c.messages.sendMedia(
              silent: true,
              background: false,
              clearDraft: false,
              noforwards: false,
              updateStickersetsOrder: false,
              invertMedia: false,
              allowPaidFloodskip: false,
              peer: const t.InputPeerSelf(),
              media: media(thumb),
              message: '',
              randomId: randomId,
            )));

    var result = await send(thumbFile);
    if (result.error != null && thumbFile != null) {
      // The file's parts are already on Telegram's servers; if it was the
      // preview it didn't like (it's undocumented which thumbs MTProto
      // rejects), send the same document again without one instead of
      // failing — and re-uploading — the whole file.
      // ignore: avoid_print
      print('TVDIAG: sendMedia with thumb failed (${result.error!.errorMessage}), retrying without');
      randomId = randomInt64();
      result = await send(null);
    }

    if (result.error != null) {
      throw UploadException('sendMedia failed: ${result.error!.errorMessage}');
    }

    final messageId = extractSentMessageId(result.result, randomId);
    if (messageId == null) {
      throw UploadException('Upload sent but message id could not be resolved.');
    }
    return messageId;
  }

  /// Uploads the preview JPEG as its own small file (same part scheme as
  /// IndexService's snapshot upload), returning null on any failure so the
  /// document just goes out without a preview.
  Future<t.InputFile?> _uploadThumb(Uint8List bytes) async {
    try {
      final fileId = randomInt64();
      const chunkSize = UploadLimits.chunkSize;
      final totalParts = (bytes.length + chunkSize - 1) ~/ chunkSize;
      for (var part = 0; part < totalParts; part++) {
        final start = part * chunkSize;
        final end = math.min(start + chunkSize, bytes.length);
        final chunk = Uint8List.sublistView(bytes, start, end);
        final result = await withAuthKeyRetry(() => TelegramService.instance.call(
              (c) => c.upload.saveFilePart(fileId: fileId, filePart: part, bytes: chunk),
            ));
        if (result.error != null) {
          // ignore: avoid_print
          print('TVDIAG: thumb upload failed: ${result.error!.errorMessage}');
          return null;
        }
      }
      return t.InputFile(id: fileId, parts: totalParts, name: 'thumb.jpg', md5Checksum: '');
    } catch (e) {
      // ignore: avoid_print
      print('TVDIAG: thumb upload failed: ${logSafeError(e)}');
      return null;
    }
  }
}

class UploadException implements Exception {
  final String message;
  UploadException(this.message);
  @override
  String toString() => 'UploadException: $message';
}
