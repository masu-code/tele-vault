import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tele_vault/core/backup/backup_registry.dart';
import 'package:tele_vault/core/backup/heartbeat.dart';
import 'package:tele_vault/core/backup/registry_store.dart';
import 'package:tele_vault/core/index/index_cache.dart';
import 'package:tele_vault/core/index/index_remote.dart';
import 'package:tele_vault/core/index/index_service.dart';
import 'package:tele_vault/features/auth/providers/auth_provider.dart';
import 'package:tele_vault/features/auth/session_cleanup.dart';
import 'package:tele_vault/features/explorer/providers/index_provider.dart';
import 'package:tele_vault/features/profile/screens/account_sheet.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

/// "Log out" (account sheet -> AuthNotifier.logOut -> SessionCleanup) and what
/// logging in as another account does to the backup registry.

SessionCleanup _cleanup(
  List<String> steps, {
  List<int>? bound,
  Future<void> Function()? onClearSession,
}) {
  Future<void> step(String name) async => steps.add(name);
  return SessionCleanup(
    stopTransfers: () => step('stop transfers'),
    cancelBackgroundTasks: () => step('cancel background tasks'),
    serverLogOut: () => step('server log out'),
    clearSession: () async {
      steps.add('clear session');
      await onClearSession?.call();
    },
    resetWorkers: () => step('reset workers'),
    clearIndex: () => step('clear index'),
    resetAppState: () => step('reset app state'),
    bindAccount: (id) async => bound?.add(id),
    resumeBackgroundTasks: () => step('resume background tasks'),
  );
}

FileItem _file(String id) => FileItem(
      id: id,
      name: 'n_$id',
      folderId: null,
      totalSize: 1,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      parts: const [FilePart(messageId: 1, part: 0, size: 1)],
    );

PendingIndexRow _row(String asset, String file) =>
    (assetId: asset, fileItemId: file, itemJson: '{}', path: '/x/$asset');

/// Serves [doc] (one index document) until [gone] is set, then no index.
class _NoIndexRemote implements IndexRemote {
  _NoIndexRemote([this.doc]);
  RemoteIndexDoc? doc;
  @override
  Future<RemoteIndexSnapshot> load(RemoteLoadArgs args) async => doc == null
      ? const RemoteIndexSnapshot(kind: RemoteIndexKind.none)
      : RemoteIndexSnapshot(kind: RemoteIndexKind.documents, docs: [doc!]);
  @override
  Future<RemoteWriteResult> write(RemoteWriteArgs args) async => throw UnimplementedError();
  @override
  Future<List<int>?> existingMessageIds(List<int> messageIds) async => messageIds;
  @override
  Future<void> deleteMessages(List<int> messageIds) async {}
  @override
  Future<int?> documentIdOf(int messageId) async => null;
  @override
  Future<List<TransferableTypedData>> scanAllSnapshots(int maxMessages) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('SessionCleanup order', () {
    test('log out: stop, cancel tasks, auth.logOut, clear session, workers, index, state',
        () async {
      final steps = <String>[];
      await _cleanup(steps).run(serverSide: true);
      expect(steps, [
        'stop transfers',
        'cancel background tasks',
        'server log out',
        'clear session',
        'reset workers',
        'clear index',
        'reset app state',
      ]);
    });

    test('a revoked session skips only the auth.logOut RPC', () async {
      final steps = <String>[];
      await _cleanup(steps).run(serverSide: false);
      expect(steps, isNot(contains('server log out')));
      expect(steps, hasLength(6));
    });

    test('a failing step never keeps the next ones from running', () async {
      final steps = <String>[];
      final failing = SessionCleanup(
        stopTransfers: () async => throw StateError('boom'),
        cancelBackgroundTasks: () async => steps.add('cancel'),
        serverLogOut: () async => throw const FormatException('offline'),
        clearSession: () async => steps.add('clear session'),
        resetWorkers: () async => throw StateError('boom'),
        clearIndex: () async => steps.add('clear index'),
        resetAppState: () async => steps.add('reset app state'),
        bindAccount: (_) async {},
        resumeBackgroundTasks: () async {},
      );
      await failing.run(serverSide: true);
      expect(steps, ['cancel', 'clear session', 'clear index', 'reset app state']);
    });
  });

  group('AuthNotifier.logOut', () {
    test('runs the cleanup (with the server logout) and lands on the login screen', () async {
      final steps = <String>[];
      final auth = AuthNotifier.withoutRestore(
        const AuthState(step: AuthStep.authenticated, restoring: false),
        cleanup: _cleanup(steps),
      );
      addTearDown(auth.dispose);

      await auth.logOut();

      expect(steps.first, 'stop transfers');
      expect(steps, contains('server log out'));
      expect(steps.indexOf('server log out'), lessThan(steps.indexOf('clear session')));
      expect(auth.state.step, AuthStep.initial);
      expect(auth.state.isAuthenticated, isFalse);
      expect(auth.state.restoring, isFalse, reason: 'the login screen, not the splash');
      expect(auth.state.error, isNull);
    });

    test('overlapping log outs run the cleanup once', () async {
      final steps = <String>[];
      final auth = AuthNotifier.withoutRestore(
        const AuthState(step: AuthStep.authenticated, restoring: false),
        cleanup: _cleanup(steps, onClearSession: () => Future<void>.delayed(const Duration(milliseconds: 30))),
      );
      addTearDown(auth.dispose);

      await Future.wait([auth.logOut(), auth.logOut(), auth.invalidateSession()]);

      expect(steps.where((s) => s == 'clear session'), hasLength(1));
    });
  });

  group('Log out button', () {
    Future<(List<String>, AuthNotifier)> pump(WidgetTester tester) async {
      final steps = <String>[];
      final auth = AuthNotifier.withoutRestore(
        const AuthState(step: AuthStep.authenticated, restoring: false),
        cleanup: _cleanup(steps),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [authProvider.overrideWith((ref) => auth)],
        child: const MaterialApp(home: Scaffold(body: LogOutButton())),
      ));
      return (steps, auth);
    }

    testWidgets('asks first; cancelling does nothing', (tester) async {
      final (steps, auth) = await pump(tester);

      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(find.text(LogOutButton.confirmBody), findsOneWidget);
      expect(find.textContaining('not touched'), findsOneWidget);
      expect(find.textContaining('backup stops'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(steps, isEmpty);
      expect(auth.state.isAuthenticated, isTrue);
    });

    testWidgets('confirming logs out', (tester) async {
      final (steps, auth) = await pump(tester);

      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      // The dialog's red action (the button label is also "Log out").
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Log out')));
      await tester.pumpAndSettle();

      expect(steps, contains('server log out'));
      expect(steps, contains('clear session'));
      expect(auth.state.isAuthenticated, isFalse);
    });
  });

  group('backup registry across accounts', () {
    late Directory dir;
    late BackupRegistry registry;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('tv_account_test_');
      Heartbeat.resetForTesting();
      SharedPreferences.setMockInitialValues({});
      registry = BackupRegistry.forTesting(
        dir: dir.path,
        factory: databaseFactoryFfi,
        prefs: await SharedPreferences.getInstance(),
      );
      await registry.init();
    });

    tearDown(() async {
      try {
        await registry.close();
      } catch (_) {}
      Heartbeat.resetForTesting();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> upload(String asset, String file) async {
      await registry.commitUploads([(assetId: asset, fileItemId: file, path: '/dcim/$asset')]);
    }

    test('the first login only records the account and keeps what is there', () async {
      await upload('a1', 'f1');
      await registry.addPendingIndex(assetId: 'a2', fileItemId: 'f2', itemJson: '{}', path: '/x');

      expect(await registry.bindAccount(100), AccountBinding.first);

      expect(registry.account, 100);
      expect(registry.isUploaded('a1'), isTrue);
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'a2'});
    });

    test('the same account logging back in keeps the registry: nothing uploads twice',
        () async {
      await registry.bindAccount(100);
      await upload('a1', 'f1');
      await registry.addPendingIndex(assetId: 'a2', fileItemId: 'f2', itemJson: '{}', path: '/x');
      await registry.setAlbumEnabled('album', enabled: true);

      // (log out and in again: the registry is not touched by the cleanup)
      expect(await registry.bindAccount(100), AccountBinding.same);

      expect(registry.isUploaded('a1'), isTrue);
      expect(registry.fileItemIdFor('a1'), 'f1');
      expect(registry.localPathFor('f1'), '/dcim/a1');
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'a2'});
      expect(registry.isAlbumEnabled('album'), isTrue);
    });

    test('a different account does not reuse the links', () async {
      await registry.bindAccount(100);
      await upload('a1', 'f1');
      await registry.setAlbumEnabled('album', enabled: true);
      await registry.setAllowMobileData(true);

      expect(await registry.bindAccount(200), AccountBinding.switched);

      expect(registry.account, 200);
      expect(registry.isUploaded('a1'), isFalse, reason: 'the new account has not backed it up');
      expect(registry.fileItemIdFor('a1'), isNull);
      expect(registry.assetIdForFileItem('f1'), isNull);
      expect(registry.localPathFor('f1'), isNull);
      expect(registry.uploadedAssetIds, isEmpty);
      // Device-level settings are not account data.
      expect(registry.isAlbumEnabled('album'), isTrue);
      expect(registry.allowMobileData, isTrue);

      // A reopened registry (another isolate / next launch) agrees.
      await registry.reload();
      expect(registry.isUploaded('a1'), isFalse);
      expect(registry.account, 200);
    });

    test('pending-index rows of the old account stay, but are never handed to the new one',
        () async {
      await registry.bindAccount(100);
      await registry.addPendingIndex(assetId: 'a1', fileItemId: 'f1', itemJson: '{}', path: '/x');

      await registry.bindAccount(200);

      // Skipped: neither listed as rows to index, nor as "uploaded, waiting".
      expect(await registry.pendingIndex(), isEmpty);
      expect(await registry.pendingIndexAssetIds(), isEmpty);
      expect(await registry.isPendingIndex('a1'), isFalse);

      // The new account's own rows work, and are the only ones returned.
      await registry.addPendingIndex(assetId: 'b1', fileItemId: 'g1', itemJson: '{}', path: '/y');
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'b1'});

      // Untouched in the database: the old account logging back in sees them.
      final store = await RegistryStore.open(
          factory: databaseFactoryFfi, path: p.join(dir.path, 'tv_registry.db'));
      addTearDown(store.close);
      final all = await store.pendingIndexTagged();
      expect({for (final r in all) r.row.assetId: r.account}, {'a1': 100, 'b1': 200});

      await registry.bindAccount(100);
      expect({for (final r in await registry.pendingIndex()) r.assetId}, {'a1'});
    });

    test('rows written before accounts were recorded are adopted by the first login',
        () async {
      // As an upgraded install has them: an account-less row.
      await registry.addPendingIndex(assetId: 'old', fileItemId: 'f0', itemJson: '{}', path: '/o');
      expect(registry.account, isNull);
      expect(await registry.pendingIndex(), hasLength(1));

      await registry.bindAccount(100);
      await registry.bindAccount(200);

      expect(await registry.pendingIndex(), isEmpty,
          reason: 'tagged as the first account\'s, so hidden from the second');
    });

    test('the headless engine reading the same database sees the bound account', () async {
      await registry.bindAccount(100);
      await registry.addPendingIndex(assetId: 'a1', fileItemId: 'f1', itemJson: '{}', path: '/x');

      final other = BackupRegistry.forTesting(
        dir: dir.path,
        factory: databaseFactoryFfi,
        prefs: await SharedPreferences.getInstance(),
      );
      addTearDown(other.close);
      await other.init();

      expect(other.account, 100);
      expect(await other.pendingIndex(), hasLength(1));

      await registry.bindAccount(200);
      await other.reload();
      expect(other.account, 200);
      expect(await other.pendingIndex(), isEmpty);
    });
  });

  group('preferences fallback storage', () {
    test('tags rows, clears links only, keeps rows and settings', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = PrefsRegistryStorage(prefs);

      await s.commitUploads([(assetId: 'a1', fileItemId: 'f1', path: '/p')]);
      await s.addPendingIndex(_row('a2', 'f2'));
      await s.setKvMany({RegistryKeys.account: '100', RegistryKeys.allowMobileData: '1'});
      await s.tagUntaggedPendingIndex(100);
      await s.addPendingIndex(_row('a3', 'f3'), account: 200);

      final tagged = await s.pendingIndexTagged();
      expect({for (final r in tagged) r.row.assetId: r.account}, {'a2': 100, 'a3': 200});

      await s.clearLinks();
      final snap = await s.load();
      expect(snap.links, isEmpty);
      expect(snap.paths, isEmpty);
      expect(snap.kv[RegistryKeys.account], '100');
      expect(snap.kv[RegistryKeys.allowMobileData], '1');
      expect(await s.pendingIndexTagged(), hasLength(2));
    });
  });

  group('local index', () {
    late Directory dir;
    late IndexCache cache;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('tv_logout_index_');
      cache = IndexCache.inDirectory(dir);
      SharedPreferences.setMockInitialValues({'tv_index_msg_id': 42, 'tv_index_msg_legacy': false});
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Uint8List bytesOf(FileIndex i) => Uint8List.fromList(utf8.encode(i.encode()));

    test('IndexCache.clear removes the cache and its meta but keeps index_backups', () async {
      final bytes = bytesOf(FileIndex(files: [_file('a')]));
      await cache.write(bytes, messageId: 7, documentId: 9, account: 1);
      await cache.backup(bytes);
      expect(await cache.read(), isNotNull);

      await cache.clear();

      expect(await cache.read(), isNull);
      expect(File(p.join(dir.path, IndexCache.cacheName)).existsSync(), isFalse);
      expect(File(p.join(dir.path, IndexCache.metaName)).existsSync(), isFalse);
      expect(await cache.listBackups(), hasLength(1));
      await cache.clear(); // nothing left: still fine
    });

    test('logging out resets the index notifier and clears the cache and message id',
        () async {
      final bytes = bytesOf(FileIndex(files: [_file('a')]));
      final remote = _NoIndexRemote(RemoteIndexDoc(
        messageId: 7,
        documentId: 9,
        size: bytes.length,
        cached: false,
        bytes: TransferableTypedData.fromList([bytes]),
      ));
      final service = IndexService.forTesting(remote: remote, cache: cache);
      final c = ProviderContainer(overrides: [
        indexProvider.overrideWith((ref) => IndexNotifier(ref, service: service)),
      ]);
      addTearDown(c.dispose);
      final notifier = c.read(indexProvider.notifier);

      await notifier.load();
      expect(c.read(indexProvider).index.files, hasLength(1));
      expect(notifier.remoteSynced, isTrue);
      expect(await cache.read(), isNotNull, reason: 'the load wrote the device cache');
      expect((await SharedPreferences.getInstance()).getInt('tv_index_msg_id'), 7);

      await notifier.clearForLogout();

      expect(c.read(indexProvider).index.files, isEmpty);
      expect(c.read(indexProvider).isLoading, isFalse);
      expect(notifier.remoteSynced, isFalse);
      expect(await cache.read(), isNull);
      expect((await SharedPreferences.getInstance()).getInt('tv_index_msg_id'), isNull);

      // The next login's load starts from scratch (nothing of the old account).
      remote.doc = null;
      await notifier.load();
      expect(c.read(indexProvider).index.files, isEmpty);
    });
  });
}
