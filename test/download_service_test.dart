import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:t/t.dart' as t;
import 'package:tele_vault/core/download/download_plan.dart';
import 'package:tele_vault/core/download/download_service.dart';
import 'package:tele_vault/core/download/download_worker.dart';
import 'package:tele_vault/core/telegram/io_socket.dart' show SocketDeadException;
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

/// Window size used by these tests: keeps the fake files small while
/// exercising multi-window documents and a last window that is not full.
const _chunk = 4096;

/// Deterministic content of message [messageId]'s document.
Uint8List _content(int messageId, int size) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 7 + messageId * 31) & 0xff));

/// A fake Telegram: documents by message id, getFile honouring the real
/// window rules, plus per-test failure injection.
class _FakeRemote {
  _FakeRemote(this.sizes);

  /// messageId -> document size.
  final Map<int, int> sizes;

  /// messageId -> current file reference generation (bumped by getMessages
  /// when [expireNext] says so).
  final Map<int, int> refGen = {};
  int getMessagesCalls = 0;
  final List<(int, int, int)> getFileCalls = []; // (docId, offset, limit)

  /// Called before answering a getFile; may throw or return a result to use
  /// instead of the real answer.
  FutureOr<t.Result<t.UploadFileBase>?> Function(int docId, int offset, int limit, int ref)?
      inject;

  Future<t.Document> fetchDocument(int messageId) async {
    getMessagesCalls++;
    final size = sizes[messageId];
    if (size == null) {
      throw DownloadException('No document found in message $messageId.',
          stage: 'getMessages', code: 'NO_DOCUMENT');
    }
    final gen = refGen[messageId] ?? 0;
    return t.Document(
      id: messageId,
      accessHash: 1,
      fileReference: Uint8List.fromList([gen]),
      date: DateTime(2026),
      mimeType: 'video/mp4',
      size: size,
      dcId: 2,
      attributes: const [],
    );
  }

  Future<t.Result<t.UploadFileBase>> getFile(
    t.InputDocumentFileLocation location,
    int offset,
    int limit,
  ) async {
    final docId = location.id;
    getFileCalls.add((docId, offset, limit));
    // The real server's rules for precise:false.
    if (offset % 4096 != 0) return _err('OFFSET_INVALID');
    if (limit % 4096 != 0 || (1024 * 1024) % limit != 0) return _err('LIMIT_INVALID');
    if (offset ~/ (1024 * 1024) != (offset + limit - 1) ~/ (1024 * 1024)) {
      return _err('LIMIT_INVALID');
    }
    final override = await inject?.call(docId, offset, limit, location.fileReference.first);
    if (override != null) return override;
    final size = sizes[docId]!;
    final data = _content(docId, size);
    final end = offset + limit > size ? size : offset + limit;
    final bytes = offset >= size ? Uint8List(0) : data.sublist(offset, end);
    return t.Result.ok(
      t.UploadFile(type: const t.StorageFilePartial(), mtime: 0, bytes: bytes),
    );
  }
}

t.Result<t.UploadFileBase> _err(String message) =>
    t.Result.error(t.RpcError(errorCode: 400, errorMessage: message));

t.Result<t.UploadFileBase> _bytes(int n) => t.Result.ok(
      t.UploadFile(type: const t.StorageFilePartial(), mtime: 0, bytes: Uint8List(n)),
    );

FileItem _item(List<(int messageId, int part, int size)> parts) => FileItem(
      id: 'item-${parts.map((p) => p.$1).join('-')}',
      name: 'clip.mp4',
      folderId: null,
      totalSize: parts.fold(0, (sum, p) => sum + p.$3),
      mimeType: 'video/mp4',
      createdAt: DateTime(2026, 1, 1),
      parts: [
        for (final p in parts) FilePart(messageId: p.$1, part: p.$2, size: p.$3),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _FakeRemote remote;
  final service = DownloadService.instance;

  void useRemote(Map<int, int> sizes) {
    remote = _FakeRemote(sizes);
    service.debugFetchDocument = remote.fetchDocument;
    service.debugGetFile = remote.getFile;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tv_download_test');
    service.debugChunkSize = _chunk;
    DownloadWorker.enabled = false;
  });

  tearDown(() async {
    service.debugFetchDocument = null;
    service.debugGetFile = null;
    service.debugChunkSize = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<List<String>> leftovers() async =>
      [for (final f in dir.listSync()) f.path].where((p) => p.endsWith('.part')).toList();

  Future<DownloadException> failure(FileItem item) async {
    try {
      await service.downloadFile(item, destDir: dir.path);
    } on DownloadException catch (e) {
      return e;
    }
    fail('download did not fail');
  }

  group('DownloadService download path', () {
    test('size that is not a multiple of the window: exact bytes, aligned windows', () async {
      useRemote({11: 3 * _chunk + 123});
      final item = _item([(11, 0, 3 * _chunk + 123)]);
      final out = await service.downloadFile(item, destDir: dir.path);
      expect(await out.readAsBytes(), _content(11, 3 * _chunk + 123));
      for (final (_, offset, limit) in remote.getFileCalls) {
        expect(offset % 4096, 0);
        expect((1024 * 1024) % limit, 0);
      }
      expect(remote.getFileCalls.length, 4);
      expect(await leftovers(), isEmpty);
    });

    test('1 MiB windows on a file that is not a multiple of 1 MiB pass the real rules', () async {
      service.debugChunkSize = DownloadLimits.nativeChunkSize;
      const size = 2 * 1024 * 1024 + 5000;
      useRemote({12: size});
      final out = await service.downloadFile(_item([(12, 0, size)]), destDir: dir.path);
      expect(await out.length(), size);
      expect(remote.getFileCalls.map((c) => c.$2), [0, 1024 * 1024, 2 * 1024 * 1024]);
    });

    test('multi-part: parts listed out of order are reassembled by part number', () async {
      useRemote({21: _chunk + 10, 22: 2 * _chunk, 23: 77});
      final item = _item([(23, 2, 77), (21, 0, _chunk + 10), (22, 1, 2 * _chunk)]);
      final progress = <double>[];
      final out = await service.downloadFile(item, destDir: dir.path, onProgress: progress.add);
      expect(await out.readAsBytes(), [
        ..._content(21, _chunk + 10),
        ..._content(22, 2 * _chunk),
        ..._content(23, 77),
      ]);
      expect(progress.last, 1.0);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
    });

    test('FILE_REFERENCE_EXPIRED: the reference is refreshed and the window retried', () async {
      useRemote({31: 2 * _chunk});
      remote.inject = (docId, offset, limit, ref) {
        if (ref == 0) {
          remote.refGen[docId] = 1; // the next getMessages hands out a fresh one
          return _err('FILE_REFERENCE_EXPIRED');
        }
        return null;
      };
      final out = await service.downloadFile(_item([(31, 0, 2 * _chunk)]), destDir: dir.path);
      expect(await out.readAsBytes(), _content(31, 2 * _chunk));
      // One getMessages for the download plus one shared refresh, even though
      // both windows hit the expired reference.
      expect(remote.getMessagesCalls, 2);
    });

    test('a reference that stays expired fails with a safe code and no temp file', () async {
      useRemote({41: 100, 42: 100});
      remote.inject = (docId, offset, limit, ref) =>
          docId == 42 ? _err('FILE_REFERENCE_EXPIRED') : null;
      final e = await failure(_item([(41, 0, 100), (42, 1, 100)]));
      expect(e.reason, 'stage=getFile code=FILE_REFERENCE_EXPIRED part=2/2');
      expect(await leftovers(), isEmpty);
      expect(File('${dir.path}${Platform.pathSeparator}clip.mp4').existsSync(), isFalse);
    });

    test('LIMIT_INVALID / OFFSET_INVALID surface as their RPC names', () async {
      useRemote({51: 100});
      remote.inject = (docId, offset, limit, ref) => _err('LIMIT_INVALID');
      expect((await failure(_item([(51, 0, 100)]))).code, 'LIMIT_INVALID');
      remote.inject = (docId, offset, limit, ref) => _err('OFFSET_INVALID');
      expect((await failure(_item([(51, 0, 100)]))).code, 'OFFSET_INVALID');
    });

    test('an RPC error that is not a plain name is logged as RPC_ERROR', () async {
      useRemote({52: 100});
      remote.inject = (docId, offset, limit, ref) => _err('weird /path/to/clip.mp4');
      final e = await failure(_item([(52, 0, 100)]));
      expect(e.code, 'RPC_ERROR');
      expect(e.reason, isNot(contains('clip')));
    });

    test('a timeout is retried once, then fails with its class name', () async {
      useRemote({61: 2 * _chunk});
      var timeouts = 0;
      remote.inject = (docId, offset, limit, ref) {
        if (offset == 0 && timeouts < 1) {
          timeouts++;
          throw TimeoutException('RPC: nothing received for 30s');
        }
        return null;
      };
      final out = await service.downloadFile(_item([(61, 0, 2 * _chunk)]), destDir: dir.path);
      expect(await out.readAsBytes(), _content(61, 2 * _chunk));

      remote.inject = (docId, offset, limit, ref) =>
          throw TimeoutException('RPC: nothing received for 30s');
      final e = await failure(_item([(61, 0, 2 * _chunk)]));
      expect(e.reason, 'stage=getFile code=TimeoutException part=1/1');
      expect(await leftovers(), isEmpty);
    });

    test('a dead socket on getMessages is retried once', () async {
      useRemote({62: 10});
      var fails = 1;
      service.debugFetchDocument = (id) async {
        if (fails-- > 0) throw const SocketDeadException();
        return remote.fetchDocument(id);
      };
      final out = await service.downloadFile(_item([(62, 0, 10)]), destDir: dir.path);
      expect(await out.length(), 10);
    });

    test('a short or empty window before the end fails instead of leaving a hole', () async {
      useRemote({71: 3 * _chunk});
      remote.inject = (docId, offset, limit, ref) => offset == _chunk ? _bytes(100) : null;
      expect((await failure(_item([(71, 0, 3 * _chunk)]))).code, 'SHORT_READ');
      remote.inject = (docId, offset, limit, ref) => offset == _chunk ? _bytes(0) : null;
      expect((await failure(_item([(71, 0, 3 * _chunk)]))).code, 'SHORT_READ');
      expect(await leftovers(), isEmpty);
    });

    test('a CDN redirect is reported as CDN_REDIRECT', () async {
      useRemote({72: 100});
      remote.inject = (docId, offset, limit, ref) => t.Result.ok(t.UploadFileCdnRedirect(
            dcId: 203,
            fileToken: Uint8List(0),
            encryptionKey: Uint8List(0),
            encryptionIv: Uint8List(0),
            fileHashes: const [],
          ));
      expect((await failure(_item([(72, 0, 100)]))).code, 'CDN_REDIRECT');
    });

    test('a missing document is NO_DOCUMENT at getMessages', () async {
      useRemote({});
      final e = await failure(_item([(81, 0, 100)]));
      expect(e.reason, 'stage=getMessages code=NO_DOCUMENT part=1/1');
    });

    test('a FLOOD_WAIT wait (WorkerProgress.report) re-reports the last progress', () async {
      useRemote({91: 2 * _chunk});
      remote.inject = (docId, offset, limit, ref) {
        if (offset == _chunk) WorkerProgress.report(0); // what _floodWaitDelay does
        return null;
      };
      final progress = <double>[];
      await service.downloadFile(_item([(91, 0, 2 * _chunk)]), destDir: dir.path,
          onProgress: progress.add);
      // Every report is a double the caller can show (never the raw 0 int),
      // and the flood report repeated a value instead of resetting to 0 late.
      expect(progress.last, 1.0);
      expect(progress.length, greaterThan(3));
    });
  });

  group('safe reasons', () {
    test('downloadFailureReason never includes the exception text', () {
      expect(
        downloadFailureReason(const FileSystemException('x', '/data/user/0/clip.mp4')),
        'stage=- code=FileSystemException',
      );
      expect(
        downloadFailureReason(DownloadException('timeout', stage: 'inactivity', code: 'TIMEOUT')),
        'stage=inactivity code=TIMEOUT',
      );
    });

    test('the worker reply carries stage/code/part and the main side keeps them', () async {
      useRemote({101: 100});
      remote.inject = (docId, offset, limit, ref) => _err('FILE_REFERENCE_EXPIRED');
      final port = ReceivePort();
      addTearDown(port.close);
      final replies = <Map>[];
      final done = Completer<void>();
      port.listen((m) {
        final msg = m as Map;
        replies.add(msg);
        if (msg['type'] != 'progress' && !done.isCompleted) done.complete();
      });
      await handleRequestForTesting(
        {
          'type': 'file',
          'id': 7,
          'item': _item([(101, 0, 100)]).toJson(),
          'destDir': dir.path,
        },
        port.sendPort,
        ensureSession: () async => true,
      );
      await done.future;
      final reply = replies.last;
      expect(reply['stage'], 'getFile');
      expect(reply['code'], 'FILE_REFERENCE_EXPIRED');
      expect(reply['part'], '1/1');

      // Main side: the reply becomes a DownloadException with the same reason.
      final mainPort = ReceivePort();
      addTearDown(mainPort.close);
      final worker = DownloadWorker.forTesting(mainPort.sendPort);
      final requests = <Map>[];
      mainPort.listen((m) => requests.add(m as Map));
      final future = worker.downloadFile(_item([(101, 0, 100)]), destDir: dir.path);
      await pumpEventQueue();
      worker.deliverForTesting({...reply, 'id': requests.single['id']});
      await expectLater(
        future,
        throwsA(isA<DownloadException>().having(
          (e) => e.reason,
          'reason',
          'stage=getFile code=FILE_REFERENCE_EXPIRED part=1/1',
        )),
      );
    });
  });

  group('per-file dedupe in the preview cache', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });

    test('a second caller joins the running download and gets its progress', () async {
      useRemote({111: 2 * _chunk});
      final gate = Completer<void>();
      remote.inject = (docId, offset, limit, ref) async {
        await gate.future;
        return null;
      };
      final item = _item([(111, 0, 2 * _chunk)]);
      final first = <double>[];
      final second = <double>[];
      final a = service.downloadIntoCache(item, onProgress: first.add);
      await pumpEventQueue();
      final b = service.downloadIntoCache(item, onProgress: second.add);
      gate.complete();
      final fa = await a;
      final fb = await b;
      expect(fa.path, fb.path);
      expect(await fa.readAsBytes(), _content(111, 2 * _chunk));
      // One download: one getFile per window, not two.
      expect(remote.getFileCalls.length, 2);
      expect(first.last, 1.0);
      expect(second.last, 1.0);
    });

    test('after a failure the next call starts a new download', () async {
      useRemote({112: 100});
      remote.inject = (docId, offset, limit, ref) => _err('FILE_REFERENCE_EXPIRED');
      final item = _item([(112, 0, 100)]);
      await expectLater(service.downloadIntoCache(item), throwsA(isA<DownloadException>()));
      remote.inject = null;
      final f = await service.downloadIntoCache(item);
      expect(await f.length(), 100);
    });
  });
}
