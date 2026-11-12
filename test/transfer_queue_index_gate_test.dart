import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tele_vault/core/backup/backup_registry.dart';
import 'package:tele_vault/core/backup/heartbeat.dart';
import 'package:tele_vault/core/index/index_cache.dart';
import 'package:tele_vault/core/index/index_remote.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/features/explorer/providers/index_provider.dart';
import 'package:tele_vault/features/transfer/providers/transfer_queue_provider.dart';

/// I2: the in-app queue dedupes every upload against the index
/// (`findUpload`). Before any load reached Telegram that index is the device
/// cache or empty, so after a reinstall with a failed first load the whole
/// album was uploaded again. The queue must not upload anything until a load
/// succeeded; the items stay queued and resume once one does.

/// Remote with no index; [offline] makes every call fail. [loadGate] holds
/// a load in flight.
class GateRemote implements IndexRemote {
  bool offline = true;
  int loads = 0;
  int writes = 0;
  Completer<void>? loadGate;

  @override
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args) async {
    loads++;
    final gate = loadGate;
    if (gate != null) await gate.future;
    if (offline) throw IndexRemoteException('Failed to read history: offline');
    return const RemoteIndexSnapshot(kind: RemoteIndexKind.none);
  }

  @override
  Future<RemoteWriteResult> write(RemoteWriteArgs args) async {
    writes++;
    throw IndexRemoteException('offline');
  }

  @override
  Future<List<int>?> existingMessageIds(List<int> messageIds) async => messageIds;

  @override
  Future<void> deleteMessages(List<int> messageIds) async {}

  @override
  Future<int?> documentIdOf(int messageId) async => null;

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
  late GateRemote remote;
  late BackupRegistry registry;
  late ProviderContainer c;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tv_queue_gate_test_');
    Heartbeat.resetForTesting();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    registry = BackupRegistry.forTesting(
      dir: dir.path,
      factory: databaseFactoryFfi,
      prefs: prefs,
    );
    remote = GateRemote();
    final service = IndexService.forTesting(
      remote: remote,
      cache: IndexCache.inDirectory(Directory('${dir.path}${Platform.pathSeparator}idx')),
    );
    c = ProviderContainer(overrides: [
      indexProvider.overrideWith((ref) => IndexNotifier(ref, service: service)),
      transferQueueProvider.overrideWith((ref) => TransferQueueNotifier(ref, registry: registry)),
    ]);
  });

  tearDown(() async {
    c.dispose();
    try {
      await registry.close();
    } catch (_) {}
    Heartbeat.resetForTesting();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('with a failed index load the queue uploads nothing and keeps the items',
      () async {
    final queue = c.read(transferQueueProvider.notifier);
    queue.enqueueUploads([_asset('a1'), _asset('a2'), _asset('a3')]);

    await _until(
      () => c.read(transferQueueProvider).currentName ==
          TransferQueueNotifier.indexNotLoadedNotice,
      reason: 'queue holds for the index',
    );
    final st = c.read(transferQueueProvider);
    expect(remote.loads, greaterThanOrEqualTo(1), reason: 'the queue tried a load');
    expect(c.read(indexProvider.notifier).remoteSynced, isFalse);
    expect(st.done, 0, reason: 'no item was processed');
    expect(st.failed, 0);
    expect(st.active, isTrue);
    expect(queue.queuedUploads, 3, reason: 'items stay queued');
    expect(remote.writes, 0);
    for (final id in ['a1', 'a2', 'a3']) {
      expect(registry.isUploaded(id), isFalse);
    }

    // Re-enqueueing the same items retries the load; still offline, still held.
    final loadsBefore = remote.loads;
    queue.enqueueUploads([_asset('a1')]);
    await _until(() => remote.loads > loadsBefore, reason: 'retry load');
    await _until(
      () => c.read(transferQueueProvider).currentName ==
          TransferQueueNotifier.indexNotLoadedNotice,
    );
    expect(queue.queuedUploads, 3);
    expect(c.read(transferQueueProvider).done, 0);

    // A load that reaches Telegram (here: the resume retry) resumes the queue.
    remote.offline = false;
    await c.read(indexProvider.notifier).load();
    expect(c.read(indexProvider.notifier).remoteSynced, isTrue);
    await _until(
      () => queue.queuedUploads == 0 && !c.read(transferQueueProvider).active,
      reason: 'queue resumed and drained',
    );
  });

  test('an upload does not start while the first load is in flight', () async {
    remote.offline = false;
    remote.loadGate = Completer<void>();
    final index = c.read(indexProvider.notifier);
    final firstLoad = index.load();

    final queue = c.read(transferQueueProvider.notifier);
    queue.enqueueUploads([_asset('b1')]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(queue.queuedUploads, 1, reason: 'held until the load settles');
    expect(c.read(transferQueueProvider).done, 0);
    expect(remote.loads, 1, reason: 'waits for the load in flight, no second one');

    remote.loadGate!.complete();
    await firstLoad;
    await _until(
      () => queue.queuedUploads == 0 && !c.read(transferQueueProvider).active,
      reason: 'runs after the load',
    );
    expect(remote.loads, 1);
  });
}
