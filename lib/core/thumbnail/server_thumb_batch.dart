import 'dart:math' as math;
import 'dart:typed_data';

import 'package:t/t.dart' as t;

import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import 'adaptive_limiter.dart';

/// Largest side (px) of a Telegram server thumbnail the gallery accepts.
const int kMaxServerThumbSide = 320;

/// At most this many ids per `messages.getMessages` call.
const int kServerThumbMessagesPerCall = 100;

/// Most concurrent `upload.getFile` calls (shared by every batch in the
/// isolate). The real limit starts here and adapts to FLOOD_WAITs.
const int kServerThumbConcurrency = 4;

/// One thumbnail to fetch: [key] is the ThumbStore key, [messageId] the
/// Telegram message that carries the file's first part. [priority]: a tile the
/// user is looking at; it takes the next free `getFile` slot before any
/// background one.
class ServerThumbTarget {
  const ServerThumbTarget(this.key, this.messageId, {this.priority = false});
  final String key;
  final int messageId;
  final bool priority;
}

/// The concurrency limit of every bulk `getFile` of this isolate (statics are
/// per isolate: each worker has its own, like its own flood gate). Created on
/// first use, and wired to the flood gate so a FLOOD_WAIT halves it.
AdaptiveLimiter get serverThumbLimiter {
  final limiter = _limiter ??= AdaptiveLimiter(max: kServerThumbConcurrency);
  TelegramService.instance.onFloodGate ??= (_) {
    limiter.onFlood();
    return limiter.limit;
  };
  return limiter;
}

AdaptiveLimiter? _limiter;

/// Argument of [fetchServerThumbs]. Plain data, sendable between isolates.
class ServerThumbArgs {
  const ServerThumbArgs(this.targets);
  final List<ServerThumbTarget> targets;
}

/// Outcome for one target.
class ServerThumbResult {
  const ServerThumbResult.ok(this.key, Uint8List this.bytes) : status = statusOk;
  const ServerThumbResult.none(this.key)
      : status = statusNone,
        bytes = null;
  const ServerThumbResult.error(this.key)
      : status = statusError,
        bytes = null;

  static const String statusOk = 'ok';

  /// The message exists but Telegram has no usable thumbnail for it (not a
  /// failure: asking again would give the same answer).
  static const String statusNone = 'none';

  /// Message missing, RPC failed, transport failed: worth retrying later.
  static const String statusError = 'error';

  final String key;
  final String status;
  final Uint8List? bytes;
}

/// The thumbnail to use from a document's [thumbs]: the largest [t.PhotoSize]
/// whose longest side is at most [kMaxServerThumbSide], or null when there is
/// none (stripped sizes and over-large ones are ignored).
t.PhotoSize? pickServerThumb(List<t.PhotoSizeBase>? thumbs) {
  if (thumbs == null) return null;
  t.PhotoSize? best;
  for (final th in thumbs) {
    if (th is! t.PhotoSize) continue;
    if (math.max(th.w, th.h) > kMaxServerThumbSide) continue;
    if (best == null || th.w * th.h > best.w * best.h) best = th;
  }
  return best;
}

/// Downloads Telegram's embedded thumbnails for up to many files in few RPCs:
/// `getMessages` for <= 100 ids per call, then `getFile` for each thumbnail,
/// up to 4 at a time through [serverThumbLimiter] (fewer while Telegram is
/// answering FLOOD_WAIT; priority targets go first). Top-level so it can run
/// through `DownloadWorker.run` (its AES work then stays off the UI isolate).
/// Never throws for per-file problems: those become `error`/`none` results.
Future<List<ServerThumbResult>> fetchServerThumbs(ServerThumbArgs args) async {
  final results = <ServerThumbResult>[];
  final targets = args.targets;
  final limiter = serverThumbLimiter;
  for (var i = 0; i < targets.length; i += kServerThumbMessagesPerCall) {
    final chunk = targets.sublist(
      i,
      math.min(i + kServerThumbMessagesPerCall, targets.length),
    );
    final documents = await _documentsFor([for (final c in chunk) c.messageId]);
    if (documents == null) {
      results.addAll([for (final c in chunk) ServerThumbResult.error(c.key)]);
      continue;
    }
    final chunkResults = await Future.wait([
      for (final target in chunk)
        limiter.run(
          () => _fetchOne(target, documents[target.messageId]),
          priority: target.priority,
        ),
    ]);
    results.addAll(chunkResults);
  }
  return results;
}

Future<Map<int, t.Document>?> _documentsFor(List<int> messageIds) async {
  try {
    final result = await TelegramService.instance.call(
      (c) => c.messages.getMessages(id: [for (final id in messageIds) t.InputMessageID(id: id)]),
    );
    if (result.error != null) return null;
    final byId = <int, t.Document>{};
    for (final m in extractMessages(result.result)) {
      if (m is! t.Message) continue;
      final media = m.media;
      if (media is t.MessageMediaDocument && media.document is t.Document) {
        byId[m.id] = media.document as t.Document;
      }
    }
    return byId;
  } catch (_) {
    return null;
  }
}

Future<ServerThumbResult> _fetchOne(ServerThumbTarget target, t.Document? doc) async {
  if (doc == null) return ServerThumbResult.error(target.key);
  final thumb = pickServerThumb(doc.thumbs);
  if (thumb == null) return ServerThumbResult.none(target.key);
  try {
    final result = await TelegramService.instance.call(
      (c) => c.upload.getFile(
        precise: false,
        cdnSupported: false,
        location: t.InputDocumentFileLocation(
          id: doc.id,
          accessHash: doc.accessHash,
          fileReference: doc.fileReference,
          thumbSize: thumb.type,
        ),
        offset: 0,
        limit: 1024 * 1024,
      ),
    );
    final file = result.result;
    if (result.error != null || file is! t.UploadFile || file.bytes.isEmpty) {
      return ServerThumbResult.error(target.key);
    }
    return ServerThumbResult.ok(target.key, file.bytes);
  } catch (_) {
    return ServerThumbResult.error(target.key);
  }
}
