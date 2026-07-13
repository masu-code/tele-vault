import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import '../../models/file_item.dart';
import '../telegram/client.dart';
import 'upload_service.dart';

class _IsolateInit {
  const _IsolateInit(this.sendPort, this.rootToken);
  final SendPort sendPort;
  final RootIsolateToken rootToken;
}

/// Runs actual Telegram uploads (multi-part AES encryption + socket I/O) on a
/// dedicated background isolate instead of the UI isolate.
///
/// A mass upload sends hundreds of 512 KB parts back-to-back, each requiring
/// real CPU work (MTProto's AES-IGE encryption) plus a network round trip.
/// Doing that on the same isolate that builds frames made Gallery's scroll
/// feel stuck no matter how cheap the tile widgets were — the frame pipeline
/// was competing with encryption/socket work for the same thread. This
/// worker holds its own independent Telegram connection (MTProto supports
/// multiple simultaneous connections on one authorization key — official
/// clients do the same for media), so it never touches the connection the
/// main isolate uses for browsing/thumbnails.
///
/// Only the raw upload happens here. Registry/index bookkeeping stays on the
/// main isolate (see TransferQueueNotifier) so there's a single place that
/// owns that state — this just hands back a [FileItem], exactly like calling
/// [UploadService.uploadFile] directly used to.
class UploadWorker {
  UploadWorker._();
  static final UploadWorker instance = UploadWorker._();

  final ReceivePort _receivePort = ReceivePort();
  SendPort? _sendPort;
  Completer<void>? _starting;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _completers = {};
  final Map<int, void Function(double)> _progressCallbacks = {};

  Future<void> _ensureStarted() {
    if (_sendPort != null) return Future.value();
    final existing = _starting;
    if (existing != null) return existing.future;

    final starting = Completer<void>();
    _starting = starting;
    _receivePort.listen(_onMessage);
    Isolate.spawn(
      _entry,
      _IsolateInit(_receivePort.sendPort, RootIsolateToken.instance!),
    );
    return starting.future;
  }

  void _onMessage(dynamic raw) {
    if (raw is SendPort) {
      _sendPort = raw;
      _starting?.complete();
      return;
    }
    final msg = (raw as Map).cast<String, dynamic>();
    final id = msg['id'] as int;
    if (msg['type'] == 'progress') {
      _progressCallbacks[id]?.call(msg['value'] as double);
      return;
    }
    _progressCallbacks.remove(id);
    _completers.remove(id)?.complete(msg);
  }

  /// Uploads the file at [path] on the worker isolate. Same contract as
  /// [UploadService.uploadFile] (same [UploadException] on failure).
  Future<FileItem> uploadFile(String path, {void Function(double)? onProgress}) async {
    await _ensureStarted();
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _completers[id] = completer;
    if (onProgress != null) _progressCallbacks[id] = onProgress;
    _sendPort!.send({'type': 'upload', 'id': id, 'path': path});
    final result = await completer.future;
    final error = result['error'] as String?;
    if (error != null) throw UploadException(error);
    return FileItem.fromJson((result['item'] as Map).cast<String, dynamic>());
  }
}

void _entry(_IsolateInit init) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(init.rootToken);
  final port = ReceivePort();
  init.sendPort.send(port.sendPort);

  final restored = await TelegramService.instance.restoreSession();
  await for (final raw in port) {
    final msg = (raw as Map).cast<String, dynamic>();
    final id = msg['id'] as int;
    if (!restored) {
      // Shouldn't happen — the main isolate is already logged in by the time
      // uploads start — but fail explicitly instead of hanging forever.
      init.sendPort.send({'id': id, 'error': 'No session to restore in upload isolate.'});
      continue;
    }
    try {
      final item = await UploadService.instance.uploadFile(
        File(msg['path'] as String),
        onProgress: (p) => init.sendPort.send({'type': 'progress', 'id': id, 'value': p}),
      );
      init.sendPort.send({'id': id, 'item': item.toJson()});
    } catch (e) {
      init.sendPort.send({'id': id, 'error': e.toString()});
    }
  }
}
