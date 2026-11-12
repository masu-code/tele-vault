import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:t/t.dart' as t;
import 'package:tele_vault/core/backup/asset_upload_service.dart';
import 'package:tele_vault/core/backup/backup_registry.dart';
import 'package:tele_vault/core/backup/headless_sync.dart';
import 'package:tele_vault/core/backup/heartbeat.dart';
import 'package:tele_vault/core/index/index_cache.dart';
import 'package:tele_vault/core/index/index_remote.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/core/telegram/io_socket.dart';
import 'package:tele_vault/features/backup/providers/backup_provider.dart';
import 'package:tele_vault/features/explorer/providers/index_provider.dart';
import 'package:tele_vault/features/transfer/providers/transfer_queue_provider.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tg/tg.dart' as tg;

/// An index write that fails after the uploads (a FLOOD_WAIT on the save)
/// must never get those uploads uploaded again: each upload is persisted as
/// a pending-index row right after it reaches Telegram, assets with a row are
/// skipped, every flush/run indexes the rows first, and the device sync backs
/// off after a failed write instead of re-enqueueing at once.

Uint8List _bytesOf(FileIndex i) => Uint8List.fromList(utf8.encode(i.encode()));
FileIndex _indexOf(Uint8List b) => FileIndex.decode(utf8.decode(b));
TransferableTypedData _ttd(Uint8List b) => TransferableTypedData.fromList([b]);

t.Result<t.Pong> _flood(int s) =>
    t.Result<t.Pong>.error(t.RpcError(errorCode: 420, errorMessage: 'FLOOD_WAIT_$s'));
const _ok = t.Result<t.Pong>.ok(t.Pong(msgId: 1, pingId: 2));

/// In-memory index message. A write first sends [rpcReplies] (if any)
/// through [TelegramService.call], as the real `remoteWrite` RPCs go, so the
/// central FLOOD_WAIT handling is what decides; [failWith] fails every write.
class PendingRemote implements IndexRemote {
  int? messageId;
  int documentId = 0;
  Uint8List? bytes;
  int _nextDoc = 100;
  int writes = 0;
  Object? failWith;
  final rpcReplies = <t.Result<t.Pong>>[];

  FileIndex get current => bytes == null ? FileIndex.empty() : _indexOf(bytes!);

  @override
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args) async {
    final id = messageId;
    if (id == null) return const RemoteIndexSnapshot(kind: RemoteIndexKind.none);
    return RemoteIndexSnapshot(kind: RemoteIndexKind.documents, docs: [
      RemoteIndexDoc(
        messageId: id,
        documentId: documentId,
        size: bytes!.length,
        cached: args.cachedDocumentId == documentId,
        bytes: args.cachedDocumentId == documentId ? null : _ttd(bytes!),
      ),
    ]);
  }

  @override
  Future<RemoteWriteResult> write(RemoteWriteArgs args) async {
    writes++;
    if (rpcReplies.isNotEmpty) {
      final r = await TelegramService.instance.call((_) async => rpcReplies.removeAt(0));
      if (r.error != null) {
        throw IndexRemoteException('Could not read the index message: ${r.error!.errorMessage}');
      }
    }
    final f = failWith;
    if (f != null) throw f;
    if (args.messageId != null && args.messageId == messageId && !args.legacy) {
      if (documentId != args.expectedDocumentId) {
        return RemoteWriteResult.conflict(
          messageId: messageId!,
          remoteBytes: _ttd(bytes!),
          remoteDocumentId: documentId,
        );
      }
    } else {
      messageId = 50;
    }
    bytes = args.bytes.materialize().asUint8List();
    documentId = _nextDoc++;
    return RemoteWriteResult.written(messageId: messageId!, documentId: documentId);
  }

  @override
  Future<List<int>?> existingMessageIds(List<int> messageIds) async => messageIds;

  @override
  Future<void> deleteMessages(List<int> messageIds) async {}

  @override
  Future<int?> documentIdOf(int id) async => id == messageId ? documentId : 0;

  @override
  Future<List<TransferableTypedData>> scanAllSnapshots(int maxMessages) async => const [];
}

AssetEntity _asset(String id) => AssetEntity(
      id: id,
      typeInt: 1,
      width: 10,
      height: 10,
      title: '$id.jpg',
      createDateSecond: 1,
      modifiedDateSecond: 1,
    );

Future<void> _until(bool Function() cond, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 10)) fail('timed out: ${reason ?? ''}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory dir;
  late PendingRemote remote;
  late BackupRegistry registry;
  late IndexService service;
  late ServerSocket server;
  final sockets = <IoSocket>[];
  final waits = <Duration>[];

  /// Asset id -> times it was uploaded to "Telegram".
  final uploads = <String, int>{};
  var nextItem = 0;

  Future<File?> originFile(AssetEntity a) async {
    final f = File(p.join(dir.path, 'photos', '${a.id}.jpg'));
    if (!f.existsSync()) {
      f.createSync(recursive: true);
      f.writeAsBytesSync(List.filled(10 + a.id.codeUnits.fold(0, (s, c) => s + c), 7));
    }
    return f;
  }

  Future<FileItem> upload(AssetEntity a, File file, void Function(double) onProgress) async {
    uploads[a.id] = (uploads[a.id] ?? 0) + 1;
    final size = await file.length();
    return FileItem(
      id: 'item-${nextItem++}',
      name: p.basename(file.path),
      folderId: null,
      totalSize: size,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      parts: [FilePart(messageId: 5000 + nextItem, part: 0, size: size)],
    );
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tv_pending_index_test_');
    Heartbeat.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    registry = BackupRegistry.forTesting(
      dir: dir.path,
      factory: databaseFactoryFfi,
      prefs: prefs,
    );
    remote = PendingRemote();
    service = IndexService.forTesting(
      remote: remote,
      cache: IndexCache.inDirectory(Directory(p.join(dir.path, 'idx'))),
    );
    uploads.clear();

    // A live-looking connection for TelegramService.call (the fake RPCs
    // never touch it); FLOOD_WAIT waits are recorded, not slept.
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.listen((_) {}, onError: (_) {}));
    Future<IoSocket> socket() async {
      final io = IoSocket(await Socket.connect(InternetAddress.loopbackIPv4, server.port));
      io.receiver.listen((_) {}, onError: (_) {});
      io.lastReceive = DateTime.now();
      sockets.add(io);
      return io;
    }

    final client = tg.Client(
      socket: await socket(),
      obfuscation: tg.Obfuscation.random(false, 2),
      authorizationKey: tg.AuthorizationKey(1, Uint8List(256), 0),
      idGenerator: tg.MessageIdGenerator(),
    );
    final svc = TelegramService.instance;
    svc.debugAttach(client, await socket());
    svc.idleProbeAfter = const Duration(hours: 1);
    waits.clear();
    svc.debugFloodWaitDelay = (d) async => waits.add(d);
  });

  tearDown(() async {
    final svc = TelegramService.instance;
    svc.debugFloodWaitDelay = null;
    svc.idleProbeAfter = const Duration(seconds: 20);
    for (final s in sockets) {
      try {
        await s.close();
      } catch (_) {}
    }
    sockets.clear();
    await server.close();
    try {
      await registry.close();
    } catch (_) {}
    Heartbeat.resetForTesting();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('in-app queue', () {
    late ProviderContainer c;

    setUp(() {
      c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: service)),
        transferQueueProvider.overrideWith((ref) => TransferQueueNotifier(
              ref,
              registry: registry,
              originFile: originFile,
              uploadAsset: upload,
            )),
      ]);
    });

    tearDown(() => c.dispose());

    Future<void> drained(TransferQueueNotifier queue) => _until(
          () => queue.queuedUploads == 0 && !c.read(transferQueueProvider).active,
          reason: 'queue drained',
        );

    test('FLOOD_WAIT_5 on the save: waited out, no re-upload, links committed', () async {
      remote.rpcReplies.addAll([_flood(5), _ok]);
      final queue = c.read(transferQueueProvider.notifier);
      queue.enqueueUploads([_asset('a1'), _asset('a2'), _asset('a3')]);
      await drained(queue);

      expect(waits, [const Duration(seconds: 6)], reason: 'one 6 s wait, then the retry');
      expect(uploads, {'a1': 1, 'a2': 1, 'a3': 1});
      for (final id in ['a1', 'a2', 'a3']) {
        expect(registry.isUploaded(id), isTrue);
        expect(registry.fileItemIdFor(id), isNotNull);
      }
      expect(await registry.pendingIndex(), isEmpty);
      expect(remote.current.files, hasLength(3));
      expect(queue.syncBackoffRemaining, Duration.zero);

      // The device sync coming back finds nothing to upload.
      queue.enqueueUploads([_asset('a1'), _asset('a2'), _asset('a3')]);
      await drained(queue);
      expect(uploads, {'a1': 1, 'a2': 1, 'a3': 1});
    });

    test('a save that keeps failing: rows kept, nothing re-uploaded, sync held, '
        'indexed later without uploading', () async {
      remote.failWith = const FloodWaitException(300);
      final queue = c.read(transferQueueProvider.notifier);
      queue.enqueueUploads([_asset('b1'), _asset('b2')]);
      await drained(queue);

      expect(uploads, {'b1': 1, 'b2': 1});
      final rows = await registry.pendingIndex();
      expect({for (final r in rows) r.assetId}, {'b1', 'b2'});
      expect(FileItem.fromJson(jsonDecode(rows.first.itemJson) as Map<String, dynamic>).id,
          rows.first.fileItemId,
          reason: 'the full FileItem is stored');
      expect(registry.isUploaded('b1'), isFalse);
      expect(queue.syncBackoffRemaining, greaterThan(const Duration(seconds: 290)),
          reason: 'backoff covers the FLOOD_WAIT, never under 60 s');

      // The device sync during the backoff: holds, re-enqueues nothing.
      final writesBefore = remote.writes;
      await c.read(backupProvider.notifier).syncAlbum(AssetPathEntity(id: 'alb', name: 'alb'));
      expect(queue.queuedUploads, 0);
      expect(c.read(transferQueueProvider).active, isFalse);

      // The same assets enqueued again anyway (another pass): skipped.
      queue.enqueueUploads([_asset('b1'), _asset('b2')]);
      await drained(queue);
      expect(uploads, {'b1': 1, 'b2': 1}, reason: 'no second upload');
      expect(remote.writes, greaterThan(writesBefore), reason: 'the run retried the index first');
      expect(await registry.pendingIndex(), hasLength(2));

      // Telegram recovers: the next run indexes them, still without uploading.
      remote.failWith = null;
      queue.retryPendingIndex();
      await _until(() => registry.isUploaded('b1') && registry.isUploaded('b2'),
          reason: 'rows indexed and linked');
      await drained(queue);
      expect(uploads, {'b1': 1, 'b2': 1});
      expect(await registry.pendingIndex(), isEmpty);
      final ids = {for (final f in remote.current.files) f.id};
      expect(ids, {for (final r in rows) r.fileItemId});
      expect(registry.fileItemIdFor('b1'), rows.firstWhere((r) => r.assetId == 'b1').fileItemId);
    });

    /// A queue whose index-failure backoff is [backoff] (the real one is 60 s).
    ProviderContainer shortBackoff(Duration backoff) => ProviderContainer(overrides: [
          indexProvider.overrideWith((ref) => IndexNotifier(ref, service: service)),
          transferQueueProvider.overrideWith((ref) => TransferQueueNotifier(
                ref,
                registry: registry,
                originFile: originFile,
                uploadAsset: upload,
                indexFailureBackoff: backoff,
              )),
        ]);

    test('after a failed write, one retry runs on its own when the backoff ends',
        () async {
      final c2 = shortBackoff(const Duration(seconds: 1));
      addTearDown(c2.dispose);
      remote.failWith = IndexRemoteException('offline');
      final queue = c2.read(transferQueueProvider.notifier);
      queue.enqueueUploads([_asset('r1')]);
      await _until(
        () => queue.queuedUploads == 0 && !c2.read(transferQueueProvider).active,
        reason: 'queue drained',
      );
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'r1'});
      expect(registry.isUploaded('r1'), isFalse);

      // Telegram recovers; no new photo, no sync, no explicit retry.
      remote.failWith = null;
      final writesBefore = remote.writes;
      await _until(() => registry.isUploaded('r1'), reason: 'scheduled retry indexed the row');
      expect(await registry.pendingIndex(), isEmpty);
      expect(uploads, {'r1': 1}, reason: 'indexed, not uploaded again');
      expect(remote.current.files.map((f) => f.id), [registry.fileItemIdFor('r1')]);

      // Exactly one retry: nothing else fires afterwards.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(remote.writes, writesBefore + 1);
    });

    test('the scheduled retry is cancelled when the queue is disposed', () async {
      final c2 = shortBackoff(const Duration(milliseconds: 300));
      remote.failWith = IndexRemoteException('offline');
      final queue = c2.read(transferQueueProvider.notifier);
      queue.enqueueUploads([_asset('r2')]);
      await _until(
        () => queue.queuedUploads == 0 && !c2.read(transferQueueProvider).active,
        reason: 'queue drained',
      );
      expect(queue.syncBackoffRemaining, greaterThan(Duration.zero));
      c2.dispose();

      remote.failWith = null;
      final writesBefore = remote.writes;
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(remote.writes, writesBefore, reason: 'no retry after dispose');
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'r2'});
    });
  });

  group('direct upload (gallery add-to-album, viewer, device album)', () {
    late ProviderContainer c;

    setUp(() {
      c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: service)),
        transferQueueProvider.overrideWith((ref) => TransferQueueNotifier(
              ref,
              registry: registry,
              originFile: originFile,
              uploadAsset: upload,
            )),
      ]);
    });

    tearDown(() => c.dispose());

    Future<FileItem> direct(String id) async {
      final a = _asset(id);
      return uploadAndIndexAsset(
        assetId: id,
        file: (await originFile(a))!,
        upload: (f) => upload(a, f, (_) {}),
        index: c.read(indexProvider.notifier),
        registry: registry,
      );
    }

    test('indexed and linked through the pending row', () async {
      await c.read(indexProvider.notifier).load();
      final item = await direct('d1');
      expect(remote.current.files.map((f) => f.id), [item.id]);
      expect(registry.isUploaded('d1'), isTrue);
      expect(registry.fileItemIdFor('d1'), item.id);
      expect(registry.localPathFor(item.id), isNotNull);
      expect(await registry.pendingIndex(), isEmpty);
    });

    test('a failed save throws, marks nothing, keeps the row; the queue indexes it '
        'without uploading again', () async {
      await c.read(indexProvider.notifier).load();
      remote.failWith = IndexRemoteException('offline');
      await expectLater(direct('d2'), throwsA(isA<Exception>()));
      expect(uploads, {'d2': 1});
      expect(registry.isUploaded('d2'), isFalse);
      expect(registry.fileItemIdFor('d2'), isNull);
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'d2'});

      remote.failWith = null;
      final queue = c.read(transferQueueProvider.notifier);
      queue.enqueueUploads([_asset('d2')]);
      await _until(() => registry.isUploaded('d2'), reason: 'row indexed by the queue');
      await _until(
        () => queue.queuedUploads == 0 && !c.read(transferQueueProvider).active,
        reason: 'queue drained',
      );
      expect(uploads, {'d2': 1}, reason: 'no second upload');
      expect(await registry.pendingIndex(), isEmpty);
      expect(remote.current.files, hasLength(1));
    });
  });

  group('headless', () {
    test('FLOOD_WAIT_5 on the save: waited out, links committed, rows cleared', () async {
      await registry.init();
      remote.rpcReplies.addAll([_flood(5), _ok]);
      final r = await runHeadlessUploadPass(
        registry: registry,
        indexService: service,
        pending: [_asset('h1'), _asset('h2')],
        budget: const Duration(minutes: 5),
        originFile: originFile,
        upload: upload,
      );
      expect(waits, [const Duration(seconds: 6)]);
      expect(r.uploaded, 2);
      expect(r.linked, 2);
      expect(uploads, {'h1': 1, 'h2': 1});
      expect(registry.isUploaded('h1') && registry.isUploaded('h2'), isTrue);
      expect(await registry.pendingIndex(), isEmpty);
      expect(remote.current.files, hasLength(2));
    });

    test('a save that fails: rows kept; the next run indexes them without uploading',
        () async {
      await registry.init();
      remote.failWith = const FloodWaitException(300);
      await expectLater(
        runHeadlessUploadPass(
          registry: registry,
          indexService: service,
          pending: [_asset('h3'), _asset('h4')],
          budget: const Duration(minutes: 5),
          originFile: originFile,
          upload: upload,
        ),
        throwsA(isA<IndexException>()),
      );
      expect(uploads, {'h3': 1, 'h4': 1});
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'h3', 'h4'});
      expect(registry.isUploaded('h3'), isFalse);

      // Next run, same assets still "pending" on the device, Telegram fine.
      remote.failWith = null;
      final r = await runHeadlessUploadPass(
        registry: registry,
        indexService: service,
        pending: [_asset('h3'), _asset('h4')],
        budget: const Duration(minutes: 5),
        originFile: originFile,
        upload: upload,
      );
      expect(uploads, {'h3': 1, 'h4': 1}, reason: 'no second upload');
      expect(r.uploaded, 0);
      expect(r.linked, 2);
      expect(registry.isUploaded('h3') && registry.isUploaded('h4'), isTrue);
      expect(await registry.pendingIndex(), isEmpty);
      expect(remote.current.files, hasLength(2));
    });
  });

  test('the pending-index table is added to an existing registry database', () async {
    // A database created by the old schema (no pending_index table).
    final path = p.join(dir.path, 'tv_registry.db');
    final old = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) async {
            await db.execute('CREATE TABLE links(asset_id TEXT PRIMARY KEY, file_id TEXT, '
                'uploaded INTEGER NOT NULL DEFAULT 0, rev INTEGER NOT NULL DEFAULT 0)');
            await db.execute('CREATE TABLE paths(file_id TEXT PRIMARY KEY, '
                'local_path TEXT NOT NULL, rev INTEGER NOT NULL DEFAULT 0)');
            await db.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)');
            await db.execute("INSERT INTO kv(k, v) VALUES('migrated_v1', '1')");
            await db.execute("INSERT INTO kv(k, v) VALUES('prefs_cleaned_v1', '1')");
            await db.execute("INSERT INTO links VALUES('old', 'f0', 1, 1)");
          },
        ));
    await old.close();

    await registry.init();
    expect(registry.usingPrefsFallback, isFalse);
    expect(registry.isUploaded('old'), isTrue, reason: 'existing rows kept');
    await registry.addPendingIndex(
        assetId: 'x', fileItemId: 'fx', itemJson: '{}', path: '/tmp/x.jpg');
    expect(await registry.isPendingIndex('x'), isTrue);
    await registry.removePendingIndex(['fx']);
    expect(await registry.pendingIndex(), isEmpty);
  });
}
