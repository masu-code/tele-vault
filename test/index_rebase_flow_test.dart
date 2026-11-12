import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tele_vault/core/index/index_cache.dart';
import 'package:tele_vault/core/index/index_remote.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/features/explorer/providers/index_provider.dart';
import 'package:tele_vault/features/profile/screens/backfill_screen.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tv_core/models.dart' show ThumbPackRef;

FileItem _file(String id, {String? name, int size = 10}) => FileItem(
      id: id,
      name: name ?? 'n_$id',
      folderId: null,
      totalSize: size,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      parts: [FilePart(messageId: 1000 + id.hashCode % 1000, part: 0, size: size)],
    );

Uint8List _bytesOf(FileIndex i) => Uint8List.fromList(utf8.encode(i.encode()));
FileIndex _indexOf(Uint8List b) => FileIndex.decode(utf8.decode(b));
List<String> _ids(FileIndex i) => [for (final f in i.files) f.id]..sort();
TransferableTypedData _ttd(Uint8List b) => TransferableTypedData.fromList([b]);

/// In-memory Telegram: one index message whose document is replaced on
/// every edit, with hooks to simulate another writer and failures.
class FakeRemote implements IndexRemote {
  int? messageId;
  int documentId = 0;
  Uint8List? bytes;
  int _nextDoc = 100;
  int writes = 0;
  int downloads = 0;
  int creates = 0;

  /// Runs at the start of each write call (another writer slipping in).
  FutureOr<void> Function(int call)? beforeWrite;

  /// Makes the next write fail its read-back verification.
  bool failVerifyOnce = false;

  /// Blocks [load] until completed (tests of the cache publish).
  Completer<void>? loadGate;

  bool offline = false;

  void seed(FileIndex index, {int msg = 7}) {
    messageId = msg;
    bytes = _bytesOf(index);
    documentId = _nextDoc++;
  }

  /// Another writer replaces the document.
  void externalWrite(FileIndex Function(FileIndex) change) {
    bytes = _bytesOf(change(_indexOf(bytes!)));
    documentId = _nextDoc++;
  }

  FileIndex get current => _indexOf(bytes!);

  @override
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args) async {
    final gate = loadGate;
    if (gate != null) await gate.future;
    if (offline) throw IndexRemoteException('Failed to read history: offline');
    final id = messageId;
    if (id == null) return const RemoteIndexSnapshot(kind: RemoteIndexKind.none);
    final cached = args.cachedDocumentId == documentId;
    if (!cached) downloads++;
    return RemoteIndexSnapshot(kind: RemoteIndexKind.documents, docs: [
      RemoteIndexDoc(
        messageId: id,
        documentId: documentId,
        size: bytes!.length,
        cached: cached,
        bytes: cached ? null : _ttd(bytes!),
      ),
    ]);
  }

  @override
  Future<RemoteWriteResult> write(RemoteWriteArgs args) async {
    final call = writes++;
    await beforeWrite?.call(call);
    if (offline) throw IndexRemoteException('offline');
    final data = args.bytes.materialize().asUint8List();
    if (args.messageId != null && args.messageId == messageId && !args.legacy) {
      if (documentId != args.expectedDocumentId) {
        return RemoteWriteResult.conflict(
          messageId: messageId!,
          remoteBytes: _ttd(bytes!),
          remoteDocumentId: documentId,
        );
      }
    } else {
      messageId = 50 + creates++;
    }
    bytes = data;
    documentId = _nextDoc++;
    if (failVerifyOnce) {
      failVerifyOnce = false;
      throw IndexRemoteException('Index write could not be verified: size 1 != 2.');
    }
    return RemoteWriteResult.written(messageId: messageId!, documentId: documentId);
  }

  @override
  Future<List<int>?> existingMessageIds(List<int> messageIds) async => messageIds;

  @override
  Future<void> deleteMessages(List<int> messageIds) async {}

  @override
  Future<int?> documentIdOf(int id) async => id == messageId ? documentId : 0;

  @override
  Future<List<TransferableTypedData>> scanAllSnapshots(int maxMessages) async =>
      [if (bytes != null) _ttd(bytes!)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeRemote remote;
  late IndexCache cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('index_flow_test');
    remote = FakeRemote();
    cache = IndexCache.inDirectory(dir);
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  IndexService newService() => IndexService.forTesting(remote: remote, cache: cache);

  Future<List<FileIndex>> backups() async => [
        for (final f in await cache.listBackups()) _indexOf(await f.readAsBytes()),
      ];

  group('IndexService.save', () {
    test('backs up the current remote bytes before writing', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final s = newService();
      final loaded = await s.load();
      await s.save(loaded.addFile(_file('b')));
      final b = await backups();
      expect(b, hasLength(1));
      expect(_ids(b.single), ['a']);
      expect(_ids(remote.current), ['a', 'b']);
    });

    test('conflict then success: rebases onto the other writer and keeps both', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final s = newService();
      final loaded = await s.load();
      remote.beforeWrite = (call) {
        if (call == 0) remote.externalWrite((i) => i.addFile(_file('headless')));
      };
      final written = await s.save(loaded.addFile(_file('app')));
      expect(_ids(written), ['a', 'app', 'headless']);
      expect(_ids(remote.current), ['a', 'app', 'headless']);
      expect(remote.writes, 2);
      expect(s.documentId, remote.documentId);
      // Both the pre-write remote and the other writer's copy were backed up.
      final b = await backups();
      expect(b.map(_ids), containsAll([
        ['a'],
        ['a', 'headless'],
      ]));
    });

    test('conflict twice: error, remote keeps the other writer, local bytes kept', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final s = newService();
      final loaded = await s.load();
      remote.beforeWrite = (call) =>
          remote.externalWrite((i) => i.addFile(_file('other$call')));
      await expectLater(s.save(loaded.addFile(_file('app'))), throwsA(isA<IndexException>()));
      expect(_ids(remote.current), ['a', 'other0', 'other1']);
      final unsaved = [
        for (final f in await cache.listBackups())
          if (f.path.endsWith('-unsaved.json')) _indexOf(await f.readAsBytes()),
      ];
      expect(unsaved, hasLength(1));
      expect(_ids(unsaved.single), containsAll(['a', 'app', 'other0']));

      // The next save (same local state) rebases and succeeds without loss.
      remote.beforeWrite = null;
      final written = await s.save(loaded.addFile(_file('app')));
      expect(_ids(written), ['a', 'app', 'other0', 'other1']);
      expect(_ids(remote.current), ['a', 'app', 'other0', 'other1']);
    });

    test('two writers adding concurrently keep both sets, no duplicates', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final app = newService();
      final headless = IndexService.forTesting(
        remote: remote,
        cache: IndexCache.inDirectory(dir),
      );
      final appIndex = await app.load();
      final hIndex = await headless.load();
      await headless.save(hIndex.addFiles([_file('h1'), _file('h2')]));
      final written = await app.save(appIndex.addFile(_file('x')));
      expect(_ids(written), ['a', 'h1', 'h2', 'x']);
      expect(_ids(remote.current), ['a', 'h1', 'h2', 'x']);
      expect(remote.creates, 0, reason: 'never a second index message');
    });

    test('re-upload of a file the other writer already added is dropped and reported', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final s = newService();
      final loaded = await s.load();
      remote.externalWrite((i) => i.addFile(_file('r', name: 'IMG.jpg', size: 5)));
      List<String>? dropped;
      final written = await s.save(
        loaded.addFile(_file('l', name: 'IMG.jpg', size: 5)),
        onDroppedDuplicates: (ids) => dropped = ids,
      );
      expect(_ids(written), ['a', 'r']);
      expect(dropped, ['l']);
    });

    test('a save before any successful load reads the remote first and rebases', () async {
      remote.seed(FileIndex(files: [_file('a'), _file('b')]));
      final s = newService();
      // Local state derived from an empty index (load failed): only additions.
      final written = await s.save(FileIndex(files: [_file('new')]));
      expect(_ids(written), ['a', 'b', 'new']);
      expect(_ids(remote.current), ['a', 'b', 'new']);
    });

    test('first save creates the index message, later saves edit it', () async {
      final s = newService();
      final loaded = await s.load();
      expect(loaded.files, isEmpty);
      await s.save(loaded.addFile(_file('a')));
      final id = remote.messageId;
      await s.save(FileIndex(files: [_file('a'), _file('b')]));
      expect(remote.messageId, id);
      expect(remote.creates, 1);
    });
  });

  group('IndexNotifier', () {
    ProviderContainer containerFor(IndexService s) {
      final c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: s)),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('publishes the cache before the remote answers', () async {
      remote.seed(FileIndex(files: [_file('a'), _file('b')]));
      // A previous session cached the index.
      await newService().load();
      remote.externalWrite((i) => i.addFile(_file('c')));

      final c = containerFor(newService());
      remote.loadGate = Completer<void>();
      final done = c.read(indexProvider.notifier).load();
      // Wait until the cache is published.
      for (var i = 0; i < 200 && c.read(indexProvider).index.files.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(_ids(c.read(indexProvider).index), ['a', 'b']);
      expect(c.read(indexProvider).isLoading, isTrue);

      remote.loadGate!.complete();
      await done;
      expect(_ids(c.read(indexProvider).index), ['a', 'b', 'c']);
      expect(c.read(indexProvider).isLoading, isFalse);
      expect(c.read(indexProvider).stale, isFalse);
    });

    test('unchanged remote is served from the cache without a download', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      await newService().load();
      final before = remote.downloads;
      final c = containerFor(newService());
      await c.read(indexProvider.notifier).load();
      expect(remote.downloads, before);
      expect(_ids(c.read(indexProvider).index), ['a']);
    });

    test('offline: the cache stays, no error, stale flag set', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      await newService().load();
      remote.offline = true;
      final c = containerFor(newService());
      await c.read(indexProvider.notifier).load();
      final st = c.read(indexProvider);
      expect(_ids(st.index), ['a']);
      expect(st.error, isNull);
      expect(st.stale, isTrue);
      expect(st.isLoading, isFalse);

      // A mutation made on the stale cache once back online is rebased onto
      // what the remote holds now.
      remote.offline = false;
      remote.externalWrite((i) => i.addFile(_file('remote')));
      await c.read(indexProvider.notifier).addFile(_file('local'));
      expect(c.read(indexProvider).mutationError, isNull);
      expect(_ids(c.read(indexProvider).index), ['a', 'local', 'remote']);
      expect(_ids(remote.current), ['a', 'local', 'remote']);
      expect(c.read(indexProvider).stale, isFalse);
    });

    test('no cache and load fails: error as before', () async {
      remote.offline = true;
      final c = containerFor(newService());
      await c.read(indexProvider.notifier).load();
      expect(c.read(indexProvider).error, isNotNull);
    });

    test('verification failure: error and state rolled back; next save recovers', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final c = containerFor(newService());
      final n = c.read(indexProvider.notifier);
      await n.load();
      remote.failVerifyOnce = true;
      await n.addFile(_file('b'));
      expect(c.read(indexProvider).mutationError, contains('verified'));
      expect(_ids(c.read(indexProvider).index), ['a']);

      await n.addFile(_file('c'));
      expect(c.read(indexProvider).mutationError, isNull);
      // The unverified write did land remotely; the rebase keeps it.
      expect(_ids(c.read(indexProvider).index), ['a', 'b', 'c']);
      expect(_ids(remote.current), ['a', 'b', 'c']);
    });

    test('conflict twice: mutation error, nothing lost locally', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final c = containerFor(newService());
      final n = c.read(indexProvider.notifier);
      await n.load();
      remote.beforeWrite = (call) =>
          remote.externalWrite((i) => i.addFile(_file('o$call')));
      await n.addFile(_file('b'));
      expect(c.read(indexProvider).mutationError, isNotNull);
      expect(_ids(c.read(indexProvider).index), ['a']);
      expect(_ids(remote.current), ['a', 'o0', 'o1']);
      final unsaved = [
        for (final f in await cache.listBackups())
          if (f.path.endsWith('-unsaved.json')) _indexOf(await f.readAsBytes()),
      ];
      expect(_ids(unsaved.single), contains('b'));
    });

    ThumbPackRef pack(int m) => ThumbPackRef(
        id: 'pk$m', messageId: m, count: 1, size: 1, createdAt: DateTime.utc(2026));

    test('a backfill write and a user mutation queued during its save both survive', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final backfillProvider = Provider<RiverpodBackfillIndex>((ref) => RiverpodBackfillIndex(ref));
      final c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: newService())),
      ]);
      addTearDown(c.dispose);
      final n = c.read(indexProvider.notifier);
      await n.load();

      Future<void>? user;
      remote.beforeWrite = (call) {
        // The user acts while the backfill's save is in flight.
        if (call == 0) user = n.addFile(_file('user'));
      };
      final written = await c.read(backfillProvider).write(
            (i) => i.addThumbPack(pack(9)).withPreviews({'a': 'th1:AAEC'}),
          );
      await user;

      expect(written.thumbPacks.map((p) => p.messageId), [9]);
      final st = c.read(indexProvider);
      expect(st.mutationError, isNull);
      expect(_ids(st.index), ['a', 'user']);
      expect(st.index.thumbPacks.map((p) => p.messageId), [9]);
      expect(st.index.files.firstWhere((f) => f.id == 'a').preview, 'th1:AAEC');
      expect(_ids(remote.current), ['a', 'user']);
      expect(remote.current.thumbPacks.map((p) => p.messageId), [9]);
      expect(remote.current.files.firstWhere((f) => f.id == 'a').preview, 'th1:AAEC');
    });

    test('applyAndSave: a user mutation queued first is seen by the mutation', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: newService())),
      ]);
      addTearDown(c.dispose);
      final n = c.read(indexProvider.notifier);
      await n.load();

      final user = n.addFile(_file('user'));
      final backfill = n.applyAndSave((i) => i.addThumbPack(pack(9)));
      await user;
      final written = await backfill;
      expect(_ids(written), ['a', 'user']);
      expect(written.thumbPacks, hasLength(1));
      expect(_ids(remote.current), ['a', 'user']);
      expect(remote.current.thumbPacks, hasLength(1));
    });

    test('applyAndSave: no save when the mutation changes nothing', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: newService())),
      ]);
      addTearDown(c.dispose);
      final n = c.read(indexProvider.notifier);
      await n.load();
      final before = remote.writes;
      final written = await n.applyAndSave((i) => i);
      expect(identical(written, c.read(indexProvider).index), isTrue);
      expect(remote.writes, before);
    });

    test('applyAndSave: failure rolls back, sets mutationError and rethrows', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: newService())),
      ]);
      addTearDown(c.dispose);
      final n = c.read(indexProvider.notifier);
      await n.load();
      remote.beforeWrite = (call) => remote.externalWrite((i) => i.addFile(_file('o$call')));
      await expectLater(n.applyAndSave((i) => i.addFile(_file('b'))), throwsA(anything));
      expect(c.read(indexProvider).mutationError, isNotNull);
      expect(c.read(indexProvider).isSaving, isFalse);
      expect(_ids(c.read(indexProvider).index), ['a']);

      // The chain is not poisoned: the next mutation runs.
      remote.beforeWrite = null;
      await n.addFile(_file('c'));
      expect(c.read(indexProvider).mutationError, isNull);
      expect(_ids(c.read(indexProvider).index), containsAll(['a', 'c']));
    });

    test('resume check reloads when another writer changed the index', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final c = containerFor(newService());
      final n = c.read(indexProvider.notifier);
      await n.load();
      await n.checkForRemoteChange();
      expect(_ids(c.read(indexProvider).index), ['a']);
      remote.externalWrite((i) => i.addFile(_file('h')));
      await n.checkForRemoteChange();
      expect(_ids(c.read(indexProvider).index), ['a', 'h']);
    });

    test('resume after an offline cold start retries the load', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      await newService().load();
      remote.offline = true;
      final c = containerFor(newService());
      final n = c.read(indexProvider.notifier);
      await n.load();
      expect(c.read(indexProvider).stale, isTrue);

      // Still offline: the retry fails quietly, the cache stays.
      await n.checkForRemoteChange();
      expect(c.read(indexProvider).stale, isTrue);
      expect(_ids(c.read(indexProvider).index), ['a']);

      // Back online (the headless run uploaded 'h' meanwhile).
      remote.offline = false;
      remote.externalWrite((i) => i.addFile(_file('h')));
      await n.checkForRemoteChange();
      final st = c.read(indexProvider);
      expect(st.stale, isFalse);
      expect(st.error, isNull);
      expect(_ids(st.index), ['a', 'h']);
    });

    test('resume after a failed load with no cache retries it', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      remote.offline = true;
      final c = containerFor(newService());
      final n = c.read(indexProvider.notifier);
      await n.load();
      expect(c.read(indexProvider).error, isNotNull);
      remote.offline = false;
      await n.checkForRemoteChange();
      expect(c.read(indexProvider).error, isNull);
      expect(_ids(c.read(indexProvider).index), ['a']);
    });

    test('resume never loads before the first load (not signed in)', () async {
      remote.seed(FileIndex(files: [_file('a')]));
      final c = containerFor(newService());
      final n = c.read(indexProvider.notifier);
      final before = remote.downloads;
      await n.checkForRemoteChange();
      expect(remote.downloads, before);
      expect(c.read(indexProvider).index.files, isEmpty);
    });

    test('resume does not reload a stale index while a mutation is queued',
        () async {
      remote.seed(FileIndex(files: [_file('a')]));
      await newService().load();
      remote.offline = true;
      final c = containerFor(newService());
      final n = c.read(indexProvider.notifier);
      await n.load();
      remote.offline = false;
      final gate = Completer<void>();
      remote.beforeWrite = (_) => gate.future;
      final mutation = n.addFile(_file('m'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final downloads = remote.downloads;
      await n.checkForRemoteChange();
      expect(remote.downloads, downloads, reason: 'skipped while queued');
      gate.complete();
      await mutation;
      expect(c.read(indexProvider).stale, isFalse);
    });
  });
}
