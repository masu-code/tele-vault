import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import '../../models/file_item.dart';
import '../telegram/client.dart';
import '../thumbnail/thumbnail_service.dart';
import 'download_service.dart';

class _IsolateInit {
  const _IsolateInit(this.sendPort, this.rootToken);
  final SendPort sendPort;
  final RootIsolateToken rootToken;
}

/// Lets a function running through [DownloadWorker.run] report progress to the
/// caller's `onProgress`. Backed by a zone value, so it is a no-op when called
/// outside of `run`.
abstract final class WorkerProgress {
  static const Symbol _zoneKey = #tvDownloadWorkerProgress;

  /// Reports [progress] (must be sendable between isolates). Messages are
  /// coalesced to at most one per 100 ms per request by the worker.
  static void report(Object progress) {
    final sink = Zone.current[_zoneKey];
    if (sink is void Function(Object)) sink(progress);
  }

  static Future<R> _runWith<R>(void Function(Object) sink, Future<R> Function() body) =>
      runZoned(body, zoneValues: {_zoneKey: sink});
}

/// Runs [start] and fails with `DownloadException('timeout')` when it neither
/// completes nor calls the `touch` callback it is handed for [timeout].
/// [onTimeout] runs first, so the caller can drop its bookkeeping (pending map
/// entries) — a reply that arrives later then finds nothing to complete. The
/// underlying future is left running; its late result or error is swallowed.
Future<T> withInactivityTimeout<T>(
  Duration timeout,
  Future<T> Function(void Function() touch) start, {
  void Function()? onTimeout,
}) {
  final out = Completer<T>();
  Timer? timer;
  void arm() {
    timer?.cancel();
    timer = Timer(timeout, () {
      if (out.isCompleted) return;
      onTimeout?.call();
      out.completeError(DownloadException('timeout'));
    });
  }

  void touch() {
    if (!out.isCompleted) arm();
  }

  arm();
  Future.sync(() => start(touch)).then((value) {
    timer?.cancel();
    if (!out.isCompleted) out.complete(value);
  }, onError: (Object e, StackTrace st) {
    timer?.cancel();
    if (!out.isCompleted) out.completeError(e, st);
  });
  return out.future;
}

/// Worker-side progress coalescing: at most one message per [interval]; the
/// latest dropped value is sent when the interval elapses (trailing edge) or on
/// [flush]. After [close] nothing is sent, so a progress message can never
/// overtake (be sent after) the final reply of its request.
@visibleForTesting
class ProgressThrottle {
  ProgressThrottle(this._send, {this.interval = const Duration(milliseconds: 100)});

  final void Function(Object) _send;
  final Duration interval;
  final Stopwatch _clock = Stopwatch()..start();
  Duration? _lastSentAt;
  Object? _lastValue;
  Object? _pending;
  bool _hasPending = false;
  bool _closed = false;
  Timer? _timer;

  void report(Object value) {
    if (_closed) return;
    final last = _lastSentAt;
    if (last == null || _clock.elapsed - last >= interval) {
      _emit(value);
      return;
    }
    _pending = value;
    _hasPending = true;
    _timer ??= Timer(interval - (_clock.elapsed - last), flush);
  }

  /// Sends the pending (coalesced) value now, if any.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_closed || !_hasPending) return;
    final v = _pending!;
    _hasPending = false;
    _pending = null;
    _emit(v);
  }

  /// Sends [value] now (dropping any pending one) unless it is the value that
  /// was sent last.
  void sendFinal(Object value) {
    _timer?.cancel();
    _timer = null;
    _hasPending = false;
    _pending = null;
    if (_closed || value == _lastValue) return;
    _emit(value);
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _hasPending = false;
  }

  void _emit(Object value) {
    _lastSentAt = _clock.elapsed;
    _lastValue = value;
    _send(value);
  }
}

/// Runs Telegram downloads (gallery thumbnails, full photos/videos for the
/// viewer, save-to-device) on a dedicated background isolate instead of the
/// UI isolate.
///
/// The MTProto layer AES-IGE-decrypts every response in pure Dart,
/// synchronously, on whichever isolate owns the connection. With downloads on
/// the main isolate a CPU profile taken during gallery use showed it ~81% in
/// AES — frozen frames and ANRs. Like the upload worker (upload_worker.dart),
/// this worker holds its own Telegram connection on the same authorization
/// key, so all of that decryption happens here and the main isolate only
/// receives a file path (or a few KB of thumbnail bytes) when it's done.
///
/// Routing is decided by [enabled]: [DownloadService] and [ThumbnailService]
/// check it and forward here only when it's true, which is only ever on the
/// main isolate (set in main() on Android). In this worker's isolate — and in
/// the headless WorkManager engine, which never runs main() — it stays false,
/// so the very same service code performs the real download instead of
/// forwarding it again.
///
/// Unlike the upload worker, requests are handled concurrently: the viewer, the
/// precacher and the thumbnail pool all ask at once, and serializing them
/// would make one big video block every thumbnail behind it. The callers
/// already bound how much runs at a time (DownloadService's windows per file,
/// ThumbnailService's pool, the per-file dedupe in downloadToCache).
///
/// Every request has an inactivity timeout ([defaultInactivityTimeout] unless
/// overridden): if no progress message or reply arrives for that long, the
/// request fails with `DownloadException('timeout')` and its bookkeeping is
/// dropped, so a dead connection can never leave a caller (or an
/// `_inFlightCache` entry) waiting forever. A reply that arrives afterwards is
/// ignored.
///
/// Protocol (Maps over SendPort, `id` correlates request and reply):
/// - request `{type: 'cache'|'file'|'thumb', id, item: FileItem.toJson()}`,
///   plus `destDir` for 'file'; or `{type: 'call', id, fn, arg}` where `fn` is
///   a top-level/static `Future<R> Function(A)` and `arg` its argument (see
///   [run]).
/// - `{id, type: 'progress', value: Object}` — zero or more, always before
///   the final reply for that id, coalesced to at most one per 100 ms (plus a
///   final 1.0 for 'cache'/'file').
/// - final reply: `{id, path}` ('cache'/'file'), `{id, bytes}` ('thumb';
///   TransferableTypedData or null), `{id, result}` ('call'), or
///   `{id, error: String}`.
class DownloadWorker {
  DownloadWorker._();

  /// Instance wired to [sendPort] without spawning an isolate. Tests drive the
  /// worker's replies through [deliverForTesting].
  @visibleForTesting
  DownloadWorker.forTesting(SendPort sendPort) : _sendPort = sendPort;

  static final DownloadWorker instance = DownloadWorker._();

  /// True only on the main isolate of the app (see class docs).
  static bool enabled = false;

  /// How long a request may go without a progress message or reply before it
  /// fails with `DownloadException('timeout')`. Large downloads report
  /// progress per chunk, so only a genuinely stalled request trips it.
  static Duration defaultInactivityTimeout = const Duration(seconds: 60);

  /// Covers spawning the isolate and getting its port back — not the session
  /// restore, which each request waits for on the worker side. A spawn that
  /// never completes would otherwise hang every download forever.
  static const Duration _startTimeout = Duration(seconds: 30);

  SendPort? _sendPort;
  Future<SendPort>? _starting;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, void Function(Object)> _progress = {};

  /// Requests currently awaiting a reply (tests).
  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Feeds [raw] as if the worker isolate had sent it (tests).
  @visibleForTesting
  void deliverForTesting(Object raw) => _onMessage(raw);

  /// Simulates the worker isolate dying (tests).
  @visibleForTesting
  void exitForTesting() => _onWorkerExit();

  Future<SendPort> _ensureStarted() {
    final ready = _sendPort;
    if (ready != null) return Future.value(ready);
    // Cleared once settled, so a failed start is retried by the next request
    // instead of every later download failing with the same stale error.
    return _starting ??= _spawn().whenComplete(() => _starting = null);
  }

  Future<SendPort> _spawn() async {
    // A fresh port per spawn: if this attempt times out and is abandoned, a
    // late reply or exit notice from its isolate lands on a closed port
    // instead of being mistaken for the live worker's.
    final port = ReceivePort();
    final handshake = Completer<SendPort>();
    port.listen((raw) {
      if (raw is SendPort) {
        if (!handshake.isCompleted) handshake.complete(raw);
      } else if (raw == null) {
        // onExit notification — the isolate died (uncaught error, OOM kill).
        port.close();
        _onWorkerExit();
      } else {
        _onMessage(raw);
      }
    });

    final spawned = Isolate.spawn(
      _entry,
      _IsolateInit(port.sendPort, RootIsolateToken.instance!),
      // A stray uncaught async error from the MTProto stack was harmless on
      // the main isolate (just reported); keep it that way here instead of
      // killing the worker and every download in flight with it.
      errorsAreFatal: false,
      onExit: port.sendPort,
    );
    spawned.then((_) {}, onError: (Object e, StackTrace st) {
      if (!handshake.isCompleted) handshake.completeError(e, st);
    });

    try {
      final sendPort = await handshake.future.timeout(_startTimeout);
      _sendPort = sendPort;
      return sendPort;
    } catch (e) {
      port.close();
      spawned.then((iso) => iso.kill(priority: Isolate.immediate), onError: (_) {});
      throw DownloadException('Download worker failed to start: $e');
    }
  }

  void _onMessage(dynamic raw) {
    final msg = (raw as Map).cast<String, dynamic>();
    final id = msg['id'] as int;
    if (msg['type'] == 'progress') {
      // Unknown id (request already timed out or finished): dropped.
      _progress[id]?.call(msg['value'] as Object);
      return;
    }
    _progress.remove(id);
    // Late reply of a request that already timed out: nothing pending, ignored.
    _pending.remove(id)?.complete(msg);
  }

  /// Fails every in-flight request instead of leaving its caller awaiting a
  /// reply that will never come; the next request spawns a new worker.
  void _onWorkerExit() {
    _sendPort = null;
    final pending = Map.of(_pending);
    _pending.clear();
    _progress.clear();
    for (final c in pending.values) {
      c.complete({'error': 'Download worker exited unexpectedly.'});
    }
  }

  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> msg, {
    void Function(Object)? onProgress,
    Duration? inactivityTimeout,
  }) async {
    final port = await _ensureStarted();
    final id = _nextId++;
    final reply = await withInactivityTimeout<Map<String, dynamic>>(
      inactivityTimeout ?? defaultInactivityTimeout,
      (touch) {
        final completer = Completer<Map<String, dynamic>>();
        _pending[id] = completer;
        _progress[id] = (v) {
          touch();
          onProgress?.call(v);
        };
        try {
          port.send({...msg, 'id': id});
        } catch (_) {
          // Not sendable (bad `fn`/`arg`): don't leave an entry behind.
          _pending.remove(id);
          _progress.remove(id);
          rethrow;
        }
        return completer.future;
      },
      onTimeout: () {
        _pending.remove(id);
        _progress.remove(id);
      },
    );
    final error = reply['error'] as String?;
    if (error != null) throw DownloadException(error);
    return reply;
  }

  /// Runs the top-level/static function [topLevelFn] with [arg] on the worker
  /// isolate (after its Telegram session is restored) and returns its result.
  ///
  /// [topLevelFn], [arg] and the result must be sendable between isolates (a
  /// top-level or static tear-off is, inside one isolate group). [onProgress]
  /// receives the values the function passes to [WorkerProgress.report]. No
  /// progress message or reply for [inactivityTimeout] (default
  /// [defaultInactivityTimeout]) fails the call with
  /// `DownloadException('timeout')`.
  ///
  /// When [enabled] is false (worker isolate, headless engine, tests) the
  /// function simply runs inline on the current isolate, with the same
  /// [WorkerProgress] behaviour.
  static Future<R> run<A, R>(
    Future<R> Function(A arg) topLevelFn,
    A arg, {
    Duration? inactivityTimeout,
    void Function(Object progress)? onProgress,
  }) async {
    if (!enabled) {
      if (onProgress == null) return topLevelFn(arg);
      return WorkerProgress._runWith<R>(onProgress, () => topLevelFn(arg));
    }
    return instance._runOnWorker<A, R>(topLevelFn, arg,
        inactivityTimeout: inactivityTimeout, onProgress: onProgress);
  }

  Future<R> _runOnWorker<A, R>(
    Future<R> Function(A arg) topLevelFn,
    A arg, {
    Duration? inactivityTimeout,
    void Function(Object progress)? onProgress,
  }) async {
    final reply = await _request(
      {'type': 'call', 'fn': topLevelFn, 'arg': arg},
      onProgress: onProgress,
      inactivityTimeout: inactivityTimeout,
    );
    return reply['result'] as R;
  }

  /// The worker-routed half of [run], on this instance (tests).
  @visibleForTesting
  Future<R> runForTesting<A, R>(
    Future<R> Function(A arg) topLevelFn,
    A arg, {
    Duration? inactivityTimeout,
    void Function(Object progress)? onProgress,
  }) =>
      _runOnWorker<A, R>(topLevelFn, arg,
          inactivityTimeout: inactivityTimeout, onProgress: onProgress);

  /// Downloads [item] into the shared preview cache on the worker. Same
  /// contract as [DownloadService.downloadIntoCache]; returns the file's path.
  Future<String> downloadToCache(
    FileItem item, {
    void Function(double)? onProgress,
  }) async {
    final reply = await _request(
      {'type': 'cache', 'item': item.toJson()},
      onProgress: onProgress == null ? null : (v) => onProgress(v as double),
    );
    return reply['path'] as String;
  }

  /// Downloads [item] into [destDir] on the worker; returns the file's path.
  Future<String> downloadFile(
    FileItem item, {
    required String destDir,
    void Function(double)? onProgress,
  }) async {
    final reply = await _request(
      {'type': 'file', 'item': item.toJson(), 'destDir': destDir},
      onProgress: onProgress == null ? null : (v) => onProgress(v as double),
    );
    return reply['path'] as String;
  }

  /// Telegram's embedded thumbnail for [item], fetched on the worker, or null
  /// when it has none.
  Future<Uint8List?> serverThumbnail(FileItem item) async {
    final reply = await _request({'type': 'thumb', 'item': item.toJson()});
    final bytes = reply['bytes'] as TransferableTypedData?;
    return bytes?.materialize().asUint8List();
  }
}

void _entry(_IsolateInit init) {
  BackgroundIsolateBinaryMessenger.ensureInitialized(init.rootToken);
  // Statics are per-isolate, so this is already false here — set explicitly
  // because forwarding from inside the worker would loop back to itself.
  DownloadWorker.enabled = false;
  final port = ReceivePort();
  init.sendPort.send(port.sendPort);
  port.listen((raw) {
    unawaited(_handle((raw as Map).cast<String, dynamic>(), init.sendPort));
  });
}

/// The worker isolate's session restore, shared by concurrent requests.
/// Reset on failure so a transient network error at startup (MIUI cutting
/// the connection) doesn't leave the worker permanently unable to download.
Future<bool>? _session;

Future<bool> _ensureSession() {
  return _session ??= TelegramService.instance.restoreSession().then(
    (ok) {
      if (!ok) _session = null;
      return ok;
    },
    onError: (Object e) {
      // ignore: avoid_print
      print('TVDIAG: download isolate restoreSession() failed: $e');
      _session = null;
      return false;
    },
  );
}

/// Runs the worker side of one request as [DownloadWorker]'s isolate does,
/// with the session restore replaced by [ensureSession] (tests).
@visibleForTesting
Future<void> handleRequestForTesting(
  Map<String, dynamic> msg,
  SendPort reply, {
  required Future<bool> Function() ensureSession,
}) =>
    _handle(msg, reply, ensureSession: ensureSession);

/// Handles one request. Every path ends in exactly one final reply, so the
/// main isolate's completer for [msg]'s id always completes.
Future<void> _handle(
  Map<String, dynamic> msg,
  SendPort reply, {
  Future<bool> Function()? ensureSession,
}) async {
  final id = msg['id'] as int;
  final throttle = ProgressThrottle(
    (v) => reply.send({'id': id, 'type': 'progress', 'value': v}),
  );
  try {
    if (!await (ensureSession ?? _ensureSession)()) {
      reply.send({'id': id, 'error': 'No session to restore in download isolate.'});
      return;
    }
    void progress(double p) => throttle.report(p);

    switch (msg['type']) {
      case 'call':
        // Dynamic call: a cast to `Future<dynamic> Function(dynamic)` would
        // fail for `Future<R> Function(A)` (parameter types are contravariant).
        final Function fn = msg['fn'] as Function;
        final result = await WorkerProgress._runWith<dynamic>(
          throttle.report,
          () => fn(msg['arg']) as Future<dynamic>,
        );
        throttle.flush();
        reply.send({'id': id, 'result': result});
      case 'cache':
        final item = FileItem.fromJson((msg['item'] as Map).cast<String, dynamic>());
        final File file =
            await DownloadService.instance.downloadIntoCache(item, onProgress: progress);
        throttle.sendFinal(1.0);
        reply.send({'id': id, 'path': file.path});
      case 'file':
        final item = FileItem.fromJson((msg['item'] as Map).cast<String, dynamic>());
        final File file = await DownloadService.instance.downloadFile(
          item,
          destDir: msg['destDir'] as String,
          onProgress: progress,
        );
        throttle.sendFinal(1.0);
        reply.send({'id': id, 'path': file.path});
      case 'thumb':
        final item = FileItem.fromJson((msg['item'] as Map).cast<String, dynamic>());
        final bytes = await ThumbnailService.instance.serverThumbnailBytes(item);
        reply.send({
          'id': id,
          'bytes': bytes == null ? null : TransferableTypedData.fromList([bytes]),
        });
      default:
        reply.send({'id': id, 'error': 'Unknown download request: ${msg['type']}'});
    }
  } catch (e) {
    // A revoked key (the user re-logged in without restarting the app) would
    // otherwise keep this worker failing forever: drop the connection and
    // re-read the saved session on the next request.
    if (e.toString().contains('AUTH_KEY_UNREGISTERED')) {
      _session = null;
      await TelegramService.instance.dropConnection();
    }
    // Plain message (not "DownloadException: ...") — the main side wraps it
    // in a DownloadException again.
    reply.send({'id': id, 'error': e is DownloadException ? e.message : e.toString()});
  } finally {
    // Nothing may be sent after the final reply (late timer, a `fn` that
    // keeps reporting after it returned).
    throttle.close();
  }
}
