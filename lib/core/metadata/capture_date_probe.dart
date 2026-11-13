import 'dart:math' as math;
import 'dart:typed_data';

import 'package:t/t.dart' as t;

import '../download/download_service.dart' show DownloadException;
import '../download/download_worker.dart' show WorkerProgress;
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import 'exif_date.dart';
import 'mp4_date.dart';

/// Bytes read from the start of a JPEG for its EXIF block (APP1 is at most
/// 64 KB and sits near the start). Divides 1 MB; read at offset 0.
const int kJpegHeaderWindow = 128 * 1024;

/// Messages per `messages.getMessages` call.
const int _messagesPerCall = 100;

/// How a file's capture time can be read from its first bytes.
enum CaptureKind { jpeg, mp4, unsupported }

/// [CaptureKind] for a MIME type. HEIC/HEIF, PNG, WebP, GIF and video
/// containers other than ISO BMFF / QuickTime are unsupported.
CaptureKind captureKindOf(String mime) {
  final m = mime.toLowerCase();
  if (m == 'image/jpeg' || m == 'image/jpg' || m == 'image/pjpeg') return CaptureKind.jpeg;
  if (m == 'video/mp4' ||
      m == 'video/quicktime' ||
      m == 'video/3gpp' ||
      m == 'video/3gpp2' ||
      m == 'video/x-m4v') {
    return CaptureKind.mp4;
  }
  return CaptureKind.unsupported;
}

/// Upper bound of the bytes a probe of [kind] reads from a document of
/// [size] bytes (for the estimate shown before a run).
int probeByteEstimate(CaptureKind kind, int size) => switch (kind) {
      CaptureKind.jpeg => math.min(size, kJpegHeaderWindow),
      CaptureKind.mp4 => math.min(size, kMp4MaxWindows * kMp4Window),
      CaptureKind.unsupported => 0,
    };

/// One item to probe. Plain data, sendable between isolates.
class CaptureProbeTarget {
  const CaptureProbeTarget(this.id, this.messageId, this.kind, {this.multiPart = false});
  final String id;

  /// Message of the item's first part.
  final int messageId;
  final CaptureKind kind;
  final bool multiPart;
}

enum CaptureProbeStatus { dated, noDate, unsupported, missing, error }

/// What a probe found. Plain data, sendable between isolates.
class CaptureProbeResult {
  const CaptureProbeResult(this.id, this.status, {this.ms, this.bytes = 0});
  final String id;
  final CaptureProbeStatus status;

  /// Capture time (epoch ms) when [status] is [CaptureProbeStatus.dated].
  final int? ms;

  /// Bytes downloaded for this item.
  final int bytes;
}

/// Reads the capture time of [target] from its first document ([docSize]
/// bytes) through [read]. Network-free given [read]; errors from [read]
/// propagate.
Future<CaptureProbeResult> probeCaptureDate(
  CaptureProbeTarget target,
  int docSize,
  RangeReader read, {
  DateTime? now,
}) async {
  switch (target.kind) {
    case CaptureKind.unsupported:
      return CaptureProbeResult(target.id, CaptureProbeStatus.unsupported);
    case CaptureKind.jpeg:
      final bytes = await read(0, kJpegHeaderWindow);
      if (!looksLikeJpegHeader(bytes)) {
        return CaptureProbeResult(target.id, CaptureProbeStatus.unsupported, bytes: bytes.length);
      }
      final ms = jpegExifCaptureMs(bytes, now: now);
      return CaptureProbeResult(
        target.id,
        ms == null ? CaptureProbeStatus.noDate : CaptureProbeStatus.dated,
        ms: ms,
        bytes: bytes.length,
      );
    case CaptureKind.mp4:
      final r = await mp4CreationMs(read, docSize, multiPart: target.multiPart, now: now);
      final status = switch (r.outcome) {
        Mp4DateOutcome.dated => CaptureProbeStatus.dated,
        Mp4DateOutcome.noDate => CaptureProbeStatus.noDate,
        Mp4DateOutcome.unsupported => CaptureProbeStatus.unsupported,
      };
      return CaptureProbeResult(target.id, status, ms: r.ms, bytes: r.bytesRead);
  }
}

/// Argument of [probeCaptureDates]. Plain data, sendable between isolates.
class CaptureProbeArgs {
  const CaptureProbeArgs(this.targets, {this.throttle = const Duration(milliseconds: 250)});
  final List<CaptureProbeTarget> targets;

  /// Pause before each ranged read, so a batch stays at a few RPCs a second.
  final Duration throttle;
}

/// Probes a batch: one `messages.getMessages` per 100 items for fresh file
/// references, then small ranged `upload.getFile` reads of each first
/// document. Read-only: nothing is uploaded, sent or deleted. Top-level so it
/// runs through `DownloadWorker.run`. A failed read marks that item as an
/// error; a FLOOD_WAIT that [TelegramService.call] gave up on is rethrown so
/// the job stops.
Future<List<CaptureProbeResult>> probeCaptureDates(CaptureProbeArgs args) async {
  final docs = <int, t.Document>{};
  final ids = [
    for (final target in args.targets)
      if (target.kind != CaptureKind.unsupported) target.messageId,
  ];
  for (var i = 0; i < ids.length; i += _messagesPerCall) {
    final chunk = ids.sublist(i, math.min(i + _messagesPerCall, ids.length));
    final result = await TelegramService.instance.call(
      (c) => c.messages.getMessages(id: [for (final id in chunk) t.InputMessageID(id: id)]),
    );
    if (result.error != null) throw DownloadException('getMessages failed');
    for (final m in extractMessages(result.result)) {
      if (m is! t.Message) continue;
      final media = m.media;
      if (media is t.MessageMediaDocument && media.document is t.Document) {
        docs[m.id] = media.document as t.Document;
      }
    }
  }

  final out = <CaptureProbeResult>[];
  for (final target in args.targets) {
    final doc = docs[target.messageId];
    if (target.kind != CaptureKind.unsupported && doc == null) {
      out.add(CaptureProbeResult(target.id, CaptureProbeStatus.missing));
      WorkerProgress.report(out.length);
      continue;
    }
    Future<Uint8List> read(int offset, int limit) async {
      await Future<void>.delayed(args.throttle);
      final location = t.InputDocumentFileLocation(
        id: doc!.id,
        accessHash: doc.accessHash,
        fileReference: doc.fileReference,
        thumbSize: '',
      );
      final result = await TelegramService.instance.call((c) => c.upload.getFile(
            precise: false,
            cdnSupported: false,
            location: location,
            offset: offset,
            limit: limit,
          ));
      if (result.error != null) throw DownloadException('getFile failed');
      final file = result.result;
      if (file is! t.UploadFile) throw DownloadException('Unexpected getFile response type.');
      return file.bytes;
    }

    try {
      out.add(await probeCaptureDate(target, doc?.size ?? 0, read));
    } on FloodWaitException {
      rethrow;
    } catch (_) {
      out.add(CaptureProbeResult(target.id, CaptureProbeStatus.error));
    }
    WorkerProgress.report(out.length);
  }
  return out;
}
