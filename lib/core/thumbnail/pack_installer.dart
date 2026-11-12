import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:t/t.dart' as t;
import 'package:tv_core/codecs.dart';
import 'package:tv_core/models.dart' show ThumbPackRef;

import '../download/download_plan.dart';
import '../download/download_service.dart';
import '../download/download_worker.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import 'thumb_store.dart';

/// Caption prefix of a thumbnail-pack message (`TELEVAULT_THUMBS_V1 <pack_id>`).
const String kThumbPackMarker = 'TELEVAULT_THUMBS_V1';

/// Largest pack document accepted: header + TOC + data limits of the format.
const int kMaxPackDocumentBytes =
    ThumbPackCodec.headerLength + ThumbPackCodec.maxTocBytes + ThumbPackCodec.maxDataBytes;

/// Argument of [installPack]. Plain data, sendable between isolates.
class PackInstallArgs {
  const PackInstallArgs({
    required this.messageId,
    required this.packId,
    required this.dirPath,
  });
  final int messageId;
  final String packId;

  /// The ThumbStore directory the files are written into.
  final String dirPath;
}

/// What an install produced. Plain data, sendable between isolates.
class PackInstallResult {
  const PackInstallResult({
    required this.packId,
    required this.messageId,
    this.installedIds = const [],
    this.previews = const {},
    this.corruptIds = const [],
    this.error,
    this.permanent = false,
  });

  final String packId;
  final int messageId;

  /// Entry ids whose `<id>.jpg` is now in the directory (written by this call
  /// or already there).
  final List<String> installedIds;

  /// `th1:` previews carried by the pack's entries, by id.
  final Map<String, String> previews;

  /// Entries that failed validation (bad CRC, unsafe id, ...).
  final List<String> corruptIds;

  /// Null on success.
  final String? error;

  /// True when retrying cannot help (not a TVTP document, wrong version, ...).
  final bool permanent;

  bool get ok => error == null;
}

/// Downloads pack [PackInstallArgs.messageId] and writes every valid entry as
/// `<dir>/<id>.jpg` unless a file for that id already exists. Idempotent: a
/// second run writes nothing new and reports the same ids. Top-level so it
/// runs through `DownloadWorker.run`.
Future<PackInstallResult> installPack(PackInstallArgs args) =>
    installPackWith(args, download: _downloadPackBytes);

/// [installPack] with the document download injected (tests).
Future<PackInstallResult> installPackWith(
  PackInstallArgs args, {
  required Future<Uint8List> Function(int messageId) download,
}) async {
  PackInstallResult failure(String message, {bool permanent = false}) =>
      PackInstallResult(
        packId: args.packId,
        messageId: args.messageId,
        error: message,
        permanent: permanent,
      );

  final Uint8List bytes;
  try {
    bytes = await download(args.messageId);
  } on _PackTooLarge {
    return failure('pack too large', permanent: true);
  } catch (e) {
    return failure('download failed: ${e.runtimeType}');
  }

  final ThumbPackDecoded decoded;
  try {
    decoded = ThumbPackCodec.decode(bytes);
  } on ThumbPackFormatException catch (e) {
    return failure('bad pack: ${e.message}', permanent: true);
  } catch (_) {
    return failure('bad pack', permanent: true);
  }

  final installed = <String>[];
  final previews = <String, String>{};
  final corrupt = List<String>.of(decoded.corruptIds);
  try {
    await Directory(args.dirPath).create(recursive: true);
  } catch (e) {
    return failure('cannot create thumbnail directory: ${e.runtimeType}');
  }
  for (final e in decoded.entries) {
    if (!ThumbKey.isSafe(e.id)) {
      corrupt.add(e.id);
      continue;
    }
    final file = File(p.join(args.dirPath, '${e.id}.jpg'));
    try {
      if (!await file.exists() || await file.length() == 0) {
        final tmp = File('${file.path}.pack${args.messageId}.tmp');
        await tmp.writeAsBytes(e.jpeg);
        await tmp.rename(file.path);
      }
    } catch (_) {
      return failure('write failed');
    }
    installed.add(e.id);
    final preview = e.preview;
    if (preview != null) previews[e.id] = preview;
  }
  return PackInstallResult(
    packId: decoded.packId,
    messageId: args.messageId,
    installedIds: installed,
    previews: previews,
    corruptIds: corrupt,
  );
}

class _PackTooLarge implements Exception {
  const _PackTooLarge();
}

/// Whole-document download of a pack message with a few parallel windows.
Future<Uint8List> _downloadPackBytes(int messageId) async {
  final doc = await DownloadService.instance.fetchDocument(messageId);
  final size = doc.size;
  if (size <= 0 || size > kMaxPackDocumentBytes) throw const _PackTooLarge();
  final out = Uint8List(size);
  final ranges = downloadRanges(size);
  var next = 0;
  var received = 0;
  Object? failure;

  Future<void> worker() async {
    while (failure == null) {
      final i = next;
      if (i >= ranges.length) return;
      next++;
      final range = ranges[i];
      try {
        final result = await TelegramService.instance.call(
          (c) => c.upload.getFile(
            precise: false,
            cdnSupported: false,
            location: t.InputDocumentFileLocation(
              id: doc.id,
              accessHash: doc.accessHash,
              fileReference: doc.fileReference,
              thumbSize: '',
            ),
            offset: range.offset,
            limit: range.limit,
          ),
        );
        final file = result.result;
        if (result.error != null || file is! t.UploadFile) {
          throw DownloadException('getFile failed');
        }
        final bytes = file.bytes;
        final end = math.min(range.offset + bytes.length, size);
        if (end > range.offset) {
          out.setRange(range.offset, end, bytes);
          received += end - range.offset;
          WorkerProgress.report(received / size);
        }
      } catch (e) {
        failure ??= e;
        return;
      }
    }
  }

  await Future.wait(List.generate(4, (_) => worker()));
  if (failure != null) throw failure!;
  if (received < size) throw DownloadException('short pack download');
  return out;
}

/// Pack messages in Saved Messages, found by their caption marker. Empty
/// (never throws) when the search fails. Returned refs have `count == 0`
/// (unknown until the pack is read). Top-level so it runs through
/// `DownloadWorker.run`.
Future<List<ThumbPackRef>> discoverPacks([Object? _]) async {
  try {
    final result = await TelegramService.instance.call((c) => c.messages.search(
          peer: const t.InputPeerSelf(),
          q: kThumbPackMarker,
          filter: const t.InputMessagesFilterDocument(),
          minDate: DateTime.fromMillisecondsSinceEpoch(0),
          maxDate: DateTime.fromMillisecondsSinceEpoch(0),
          offsetId: 0,
          addOffset: 0,
          limit: 100,
          maxId: 0,
          minId: 0,
          hash: 0,
        ));
    if (result.error != null) return const [];
    final refs = <ThumbPackRef>[];
    for (final m in extractMessages(result.result)) {
      if (m is! t.Message) continue;
      final media = m.media;
      if (media is! t.MessageMediaDocument || media.document is! t.Document) continue;
      if (!m.message.startsWith('$kThumbPackMarker ')) continue;
      final packId = m.message.substring(kThumbPackMarker.length + 1).trim();
      if (packId.isEmpty) continue;
      final doc = media.document as t.Document;
      refs.add(ThumbPackRef(
        id: packId,
        messageId: m.id,
        count: 0,
        size: doc.size,
        createdAt: m.date.toUtc(),
      ));
    }
    return refs;
  } catch (_) {
    return const [];
  }
}
