import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tele_vault/core/backup/backup_registry.dart';
import 'package:tele_vault/core/backup/heartbeat.dart';
import 'package:tele_vault/core/backup/registry_store.dart';

const _assetCount = 5000;

Map<String, Object> _legacyPrefs({int assets = _assetCount}) {
  final m = <String, Object>{};
  for (var i = 0; i < assets; i++) {
    // Mix: fully linked, uploaded-without-link (app killed mid-way), and a
    // false flag that must not count as uploaded.
    if (i % 10 == 9) {
      m['bk_up_a$i'] = true; // uploaded, never linked
      continue;
    }
    if (i % 10 == 8) {
      m['bk_up_a$i'] = false;
      continue;
    }
    m['bk_up_a$i'] = true;
    m['bk_item_a$i'] = 'f$i';
    m['bk_asset_f$i'] = 'a$i';
    m['bk_link_f$i'] = '/storage/emulated/0/DCIM/img_$i.jpg';
  }
  // Path-only link: an upload that did not come from a device asset.
  m['bk_link_fileOnly'] = '/storage/emulated/0/Download/doc.pdf';
  m['bk_enabled_albums'] = <String>['alb1', 'alb2'];
  m['bk_allow_mobile_data'] = true;
  m['bk_headless_run_ms'] = 1700000000000;
  m['bk_headless_status'] = 'skipped - test';
  m['bk_queue_heartbeat_ms'] = 1;
  m['bk_app_alive_ms'] = 2;
  m['unrelated_key'] = 'keep me';
  m['bk_unknown_future_key'] = 'keep me too';
  return m;
}

int _expectedUploaded(int assets) {
  var n = 0;
  for (var i = 0; i < assets; i++) {
    if (i % 10 != 8) n++;
  }
  return n;
}

int _expectedLinked(int assets) {
  var n = 0;
  for (var i = 0; i < assets; i++) {
    if (i % 10 < 8) n++;
  }
  return n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  late Directory dir;
  final open = <BackupRegistry>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tv_registry_test_');
    Heartbeat.resetForTesting();
  });

  tearDown(() async {
    for (final r in open) {
      try {
        await r.close();
      } catch (_) {}
    }
    open.clear();
    Heartbeat.resetForTesting();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<BackupRegistry> makeRegistry({
    Map<String, Object>? prefsValues,
    SharedPreferences? prefs,
    int? crashAfter,
  }) async {
    if (prefs == null) {
      SharedPreferences.setMockInitialValues(prefsValues ?? {});
      prefs = await SharedPreferences.getInstance();
    }
    final r = BackupRegistry.forTesting(
      dir: dir.path,
      factory: factory,
      prefs: prefs,
      simulateCrashAfterRemovals: crashAfter,
    );
    open.add(r);
    return r;
  }

  group('registry API on a fresh database', () {
    test('uploaded / links / paths / reverse lookups / unlink', () async {
      final r = await makeRegistry();
      await r.init();
      expect(r.usingPrefsFallback, isFalse);
      expect(r.isUploaded('a1'), isFalse);

      await r.markUploaded('a1');
      await r.linkLocalPath('f1', '/p/1.jpg');
      await r.linkFileItem('a1', 'f1');
      expect(r.isUploaded('a1'), isTrue);
      expect(r.uploadedAssetIds, {'a1'});
      expect(r.localPathFor('f1'), '/p/1.jpg');
      expect(r.fileItemIdFor('a1'), 'f1');
      expect(r.assetIdForFileItem('f1'), 'a1');

      // linkFileItem must not drop the uploaded flag, and the data must
      // survive a restart.
      await r.close();
      final r2 = await makeRegistry();
      await r2.init();
      expect(r2.isUploaded('a1'), isTrue);
      expect(r2.fileItemIdFor('a1'), 'f1');
      expect(r2.assetIdForFileItem('f1'), 'a1');
      expect(r2.localPathFor('f1'), '/p/1.jpg');

      await r2.unlinkFileItem('f1');
      expect(r2.isUploaded('a1'), isFalse);
      expect(r2.fileItemIdFor('a1'), isNull);
      expect(r2.assetIdForFileItem('f1'), isNull);
      expect(r2.localPathFor('f1'), isNull);
      await r2.close();
      final r3 = await makeRegistry();
      await r3.init();
      expect(r3.isUploaded('a1'), isFalse);
      expect(r3.localPathFor('f1'), isNull);
    });

    test('clearUploaded keeps the link, drops a bare flag', () async {
      final r = await makeRegistry();
      await r.init();
      await r.markUploaded('bare');
      await r.markUploaded('linked');
      await r.linkFileItem('linked', 'fl');
      await r.clearUploaded('bare');
      await r.clearUploaded('linked');
      expect(r.isUploaded('bare'), isFalse);
      expect(r.isUploaded('linked'), isFalse);
      expect(r.fileItemIdFor('linked'), 'fl');
      await r.close();
      final r2 = await makeRegistry();
      await r2.init();
      expect(r2.uploadedAssetIds, isEmpty);
      expect(r2.fileItemIdFor('linked'), 'fl');
    });

    test('commitUploads is one batch and equals the single calls', () async {
      final r = await makeRegistry();
      await r.init();
      await r.commitUploads([
        for (var i = 0; i < 8; i++)
          (assetId: 'a$i', fileItemId: 'f$i', path: '/p/$i.jpg'),
      ]);
      for (var i = 0; i < 8; i++) {
        expect(r.isUploaded('a$i'), isTrue);
        expect(r.fileItemIdFor('a$i'), 'f$i');
        expect(r.assetIdForFileItem('f$i'), 'a$i');
        expect(r.localPathFor('f$i'), '/p/$i.jpg');
      }
      await r.close();
      final r2 = await makeRegistry();
      await r2.init();
      expect(r2.uploadedAssetIds.length, 8);
      expect(r2.localPathFor('f7'), '/p/7.jpg');
    });

    test('settings and headless status', () async {
      final r = await makeRegistry();
      await r.init();
      expect(r.allowMobileData, isFalse);
      expect(r.enabledAlbumIds, isEmpty);
      expect(r.lastHeadlessRun, isNull);

      await r.setAllowMobileData(true);
      await r.setAlbumEnabled('x', enabled: true);
      await r.setAlbumEnabled('y', enabled: true);
      await r.setAlbumEnabled('x', enabled: true); // no duplicate
      await r.setAlbumEnabled('y', enabled: false);
      await r.recordHeadlessRun('ok');
      await r.close();

      final r2 = await makeRegistry();
      await r2.init();
      expect(r2.allowMobileData, isTrue);
      expect(r2.enabledAlbumIds, ['x']);
      expect(r2.isAlbumEnabled('x'), isTrue);
      expect(r2.isAlbumEnabled('y'), isFalse);
      expect(r2.lastHeadlessRun?.status, 'ok');
    });

    test('getters before init throw instead of answering "not uploaded"', () async {
      final r = await makeRegistry();
      expect(() => r.isUploaded('a'), throwsStateError);
    });
  });

  group('migration from SharedPreferences', () {
    test('5000 assets: backup first, counts verified, keys removed', () async {
      final values = _legacyPrefs();
      final r = await makeRegistry(prefsValues: values);
      await r.init();

      expect(r.usingPrefsFallback, isFalse);
      expect(r.lastMigration?.status, MigrationStatus.migrated);
      expect(r.lastMigration?.uploaded, _expectedUploaded(_assetCount));
      expect(r.lastMigration?.links, _expectedLinked(_assetCount));

      // Mirror equals the legacy data.
      expect(r.uploadedAssetIds.length, _expectedUploaded(_assetCount));
      for (var i = 0; i < _assetCount; i += 37) {
        final up = i % 10 != 8;
        expect(r.isUploaded('a$i'), up, reason: 'asset $i');
        if (i % 10 < 8) {
          expect(r.fileItemIdFor('a$i'), 'f$i');
          expect(r.assetIdForFileItem('f$i'), 'a$i');
          expect(r.localPathFor('f$i'), '/storage/emulated/0/DCIM/img_$i.jpg');
        } else {
          expect(r.fileItemIdFor('a$i'), isNull);
        }
      }
      expect(r.localPathFor('fileOnly'), '/storage/emulated/0/Download/doc.pdf');
      expect(r.enabledAlbumIds, ['alb1', 'alb2']);
      expect(r.allowMobileData, isTrue);
      expect(r.lastHeadlessRun?.status, 'skipped - test');
      expect(r.lastHeadlessRun?.at.millisecondsSinceEpoch, 1700000000000);

      // Backup file exists and holds EVERY bk_* entry that was there.
      final backup = File(p.join(dir.path, 'tv_registry_prefs_backup.json'));
      expect(backup.existsSync(), isTrue);
      final entries = (jsonDecode(backup.readAsStringSync())
          as Map<String, dynamic>)['entries'] as Map<String, dynamic>;
      final bkKeys = values.keys.where((k) => k.startsWith('bk_')).toList();
      expect(entries.length, bkKeys.length);
      expect(entries['bk_up_a0'], true);
      expect(entries['bk_item_a0'], 'f0');

      // Migrated keys are gone from prefs; unrelated/unknown ones are kept.
      final prefs = await SharedPreferences.getInstance();
      final left = prefs.getKeys();
      expect(left, containsAll(['unrelated_key', 'bk_unknown_future_key']));
      expect(left.length, 2);
    });

    test('idempotent: re-running changes nothing and loses nothing', () async {
      final r = await makeRegistry(prefsValues: _legacyPrefs(assets: 400));
      await r.init();
      final snapshot = r.uploadedAssetIds;
      final prefs = await SharedPreferences.getInstance();
      await r.close();

      final r2 = await makeRegistry(prefs: prefs);
      await r2.init();
      expect(r2.lastMigration?.status, MigrationStatus.alreadyDone);
      expect(r2.uploadedAssetIds, snapshot);
      expect(r2.localPathFor('f1'), '/storage/emulated/0/DCIM/img_1.jpg');
      await r2.close();

      // Even if stale legacy keys reappear (e.g. restored prefs), the flag
      // wins: they are not re-imported over newer database data.
      await prefs.setBool('bk_up_zombie', true);
      final r3 = await makeRegistry(prefs: prefs);
      await r3.init();
      expect(r3.isUploaded('zombie'), isFalse);
      expect(r3.uploadedAssetIds, snapshot);
    });

    test('crash between copy and delete leaves a consistent state', () async {
      final values = _legacyPrefs(assets: 1000);
      final crashing = await makeRegistry(prefsValues: values, crashAfter: 100);
      await expectLater(crashing.init(), throwsA(isA<StateError>()));

      // Prefs are half cleaned, the database is complete and flagged.
      final prefs = await SharedPreferences.getInstance();
      final legacyLeft =
          prefs.getKeys().where(RegistryKeys.isLegacyKey).length;
      expect(legacyLeft, greaterThan(0));
      expect(legacyLeft, lessThan(values.length - 2));

      final r = await makeRegistry(prefs: prefs);
      await r.init();
      expect(r.lastMigration?.status, MigrationStatus.alreadyDone);
      expect(r.uploadedAssetIds.length, _expectedUploaded(1000));
      for (var i = 0; i < 1000; i++) {
        if (i % 10 < 8) {
          expect(r.fileItemIdFor('a$i'), 'f$i', reason: 'asset $i');
          expect(r.localPathFor('f$i'), isNotNull, reason: 'path f$i');
        }
      }
      expect(r.enabledAlbumIds, ['alb1', 'alb2']);
      // Leftovers were cleaned on this run.
      expect(prefs.getKeys().where(RegistryKeys.isLegacyKey), isEmpty);
    });

    test('unparseable legacy key: prefs untouched, registry keeps working', () async {
      final values = _legacyPrefs(assets: 50);
      values['bk_up_broken'] = 'not-a-bool';
      final r = await makeRegistry(prefsValues: values);
      await r.init();

      expect(r.usingPrefsFallback, isTrue);
      expect(r.lastMigration?.status, MigrationStatus.failed);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().length, values.length, reason: 'nothing removed');

      // Reads come from prefs, writes go to prefs.
      expect(r.isUploaded('a0'), isTrue);
      expect(r.fileItemIdFor('a0'), 'f0');
      expect(r.localPathFor('f0'), isNotNull);
      await r.markUploaded('new1');
      await r.linkFileItem('new1', 'fnew1');
      expect(prefs.getBool('bk_up_new1'), isTrue);
      expect(prefs.getString('bk_asset_fnew1'), 'new1');
      await r.unlinkFileItem('fnew1');
      expect(prefs.getBool('bk_up_new1'), isNull);
    });

    test('nothing to migrate on a fresh install', () async {
      final r = await makeRegistry();
      await r.init();
      expect(r.lastMigration?.status, MigrationStatus.nothingToMigrate);
      expect(r.usingPrefsFallback, isFalse);
    });

    test('a reverse-only legacy link is not lost', () async {
      final r = await makeRegistry(prefsValues: {
        'bk_up_a1': true,
        'bk_asset_f1': 'a1', // forward bk_item_a1 missing
      });
      await r.init();
      expect(r.fileItemIdFor('a1'), 'f1');
      expect(r.assetIdForFileItem('f1'), 'a1');
      expect(r.lastMigration?.detail, contains('reconstructed=1'));
    });
  });

  group('reload across isolates (two instances on one database)', () {
    test('rows and deletions written by another instance are seen', () async {
      final app = await makeRegistry();
      await app.init();
      final headless = await makeRegistry(prefs: await SharedPreferences.getInstance());
      await headless.init();

      // Headless uploads two files; the app's mirror is stale until reload.
      await headless.commitUploads([
        (assetId: 'h1', fileItemId: 'fh1', path: '/p/h1.jpg'),
        (assetId: 'h2', fileItemId: 'fh2', path: '/p/h2.jpg'),
      ]);
      await headless.recordHeadlessRun('uploaded 2');
      expect(app.isUploaded('h1'), isFalse, reason: 'stale before reload');
      await app.reload();
      expect(app.isUploaded('h1'), isTrue);
      expect(app.isUploaded('h2'), isTrue);
      expect(app.assetIdForFileItem('fh2'), 'h2');
      expect(app.localPathFor('fh1'), '/p/h1.jpg');
      expect(app.lastHeadlessRun?.status, 'uploaded 2');

      // A change to an existing row (flag cleared) is picked up too.
      await headless.clearUploaded('h1');
      await app.reload();
      expect(app.isUploaded('h1'), isFalse);
      expect(app.fileItemIdFor('h1'), 'fh1');

      // The app deletes a cloud file: the headless mirror must drop it.
      await app.unlinkFileItem('fh2');
      await headless.reload();
      expect(headless.isUploaded('h2'), isFalse);
      expect(headless.localPathFor('fh2'), isNull);
      expect(headless.assetIdForFileItem('fh2'), isNull);

      // And the first write after a full reload is still incremental-safe.
      await app.markUploaded('h3');
      await headless.reload();
      expect(headless.isUploaded('h3'), isTrue);
    });
  });

  group('Heartbeat', () {
    test('touch is throttled, isFresh honours maxAge, no write when idle', () async {
      Heartbeat.configure(dir.path);
      var now = DateTime(2026, 1, 1, 12);
      Heartbeat.clock = () => now;

      expect(Heartbeat.isFresh('app', const Duration(seconds: 60)), isFalse);
      await Heartbeat.touch('app');
      final file = File(p.join(dir.path, 'hb_app'));
      expect(file.readAsStringSync(), '${now.millisecondsSinceEpoch}');
      expect(Heartbeat.isFresh('app', const Duration(seconds: 60)), isTrue);

      // Within 15 s: no write.
      final firstContent = file.readAsStringSync();
      now = now.add(const Duration(seconds: 10));
      await Heartbeat.touch('app');
      expect(file.readAsStringSync(), firstContent);

      // After 15 s: written again.
      now = now.add(const Duration(seconds: 6));
      await Heartbeat.touch('app');
      expect(file.readAsStringSync(), '${now.millisecondsSinceEpoch}');

      // Freshness expires.
      now = now.add(const Duration(seconds: 61));
      expect(Heartbeat.isFresh('app', const Duration(seconds: 60)), isFalse);
      expect(Heartbeat.isFresh('queue', const Duration(seconds: 45)), isFalse);
      expect(() => Heartbeat.touch('bogus'), throwsArgumentError);
    });

    test('registry heartbeats delegate to the files', () async {
      final r = await makeRegistry();
      await r.init();
      expect(r.appRecentlyAlive, isFalse);
      expect(r.queueRecentlyActive, isFalse);
      await r.markAppAlive();
      await r.markQueueHeartbeat();
      expect(r.appRecentlyAlive, isTrue);
      expect(r.queueRecentlyActive, isTrue);
      expect(File(p.join(dir.path, 'hb_app')).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'hb_queue')).existsSync(), isTrue);
    });
  });
}
