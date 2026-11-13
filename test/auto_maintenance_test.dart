import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/metadata/capture_date_probe.dart';
import 'package:tele_vault/core/metadata/capture_date_recovery.dart';
import 'package:tele_vault/core/thumbnail/auto_maintenance_service.dart';
import 'package:tele_vault/core/thumbnail/auto_pack_service.dart';
import 'package:tele_vault/core/thumbnail/backfill_service.dart';
import 'package:tele_vault/core/thumbnail/backfill_state.dart';
import 'package:tele_vault/core/thumbnail/pack_installer.dart';
import 'package:tele_vault/core/thumbnail/preview_table.dart';
import 'package:tele_vault/core/thumbnail/server_thumb_batch.dart';
import 'package:tele_vault/core/thumbnail/thumb_store.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tele_vault/models/thumb_pack_ref.dart';
import 'package:tv_core/codecs.dart';

final Uint8List _thumb = () {
  final im = img.Image(width: 8, height: 6);
  img.fill(im, color: img.ColorRgb8(30, 140, 90));
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}();

String _id(int i) => 'm${i.toString().padLeft(5, '0')}';

/// Media dated by upload time (capture-date candidates) with no thumbnail.
FileIndex _library(int n) => FileIndex(files: [
      for (var i = 0; i < n; i++)
        FileItem(
          id: _id(i),
          name: 'h4sh${i}xq.jpeg',
          folderId: null,
          totalSize: 1000,
          mimeType: 'image/jpeg',
          createdAt: DateTime.utc(2025, 1, 1),
          parts: [FilePart(messageId: 1000 + i, part: 0, size: 1000)],
        ),
    ]);

class _FakeIndex implements BackfillIndexAccess {
  _FakeIndex(this.index);
  FileIndex index;
  int writes = 0;

  @override
  FileIndex? current() => index;

  @override
  Future<FileIndex> write(FileIndex Function(FileIndex current) mutate) async {
    final next = mutate(index);
    if (identical(next, index)) return index;
    writes++;
    index = FileIndex.decode(next.encode());
    return index;
  }
}

/// Every item has a Telegram server thumbnail; packs are kept in memory.
class _FakeRemote implements BackfillRemote {
  final serverThumbTargets = <String>[];
  final fetched = <String>[];
  final uploads = <(String, int, Uint8List)>[];
  var _next = 900000;

  @override
  Future<List<BackfillProbe>> probe(List<int> messageIds) async =>
      [for (final m in messageIds) BackfillProbe(m, exists: true, hasServerThumb: true)];

  @override
  Future<List<ServerThumbResult>> serverThumbs(List<ServerThumbTarget> targets) async {
    serverThumbTargets.addAll(targets.map((t) => t.key));
    return [for (final t in targets) ServerThumbResult.ok(t.key, _thumb)];
  }

  @override
  Future<BackfillOriginal> fetchOriginal(FileItem item, String workDir) async {
    fetched.add(item.id);
    throw StateError('no original downloads expected');
  }

  @override
  Future<int> uploadPack(String path, String packId) async {
    final id = _next++;
    uploads.add((packId, id, await File(path).readAsBytes()));
    return id;
  }

  @override
  Future<ThumbPackRef?> findPack(String packId) async => null;

  @override
  Future<PackInstallResult> installPack(PackInstallArgs args) async =>
      throw StateError('no installs expected');

  List<String> packedIds() => [
        for (final u in uploads)
          for (final e in ThumbPackCodec.decode(u.$3).entries) e.id,
      ];
}

class _Codec implements BackfillCodec {
  @override
  bool engineCanDecode(String mime) => true;
  @override
  Future<bool> ffmpegAvailable() async => false;
  @override
  Future<EncodedThumb?> encodeImage(File file) async => null;
  @override
  Future<EncodedThumb?> encodeWithFfmpeg(File file, String workDir) async => null;
  @override
  Future<Uint8List?> previewOf(Uint8List jpeg) async => null;
}

class _DateRemote implements CaptureDateRemote {
  final probed = <String>[];
  @override
  Future<List<CaptureProbeResult>> probe(List<CaptureProbeTarget> targets) async {
    probed.addAll(targets.map((t) => t.id));
    return [for (final t in targets) CaptureProbeResult(t.id, CaptureProbeStatus.noDate, bytes: 10)];
  }
}

class _Env {
  _Env(this.root, int items) : index = _FakeIndex(_library(items)) {
    store = ThumbStore.withDirectory(() async => Directory(p.join(root.path, 'thumbs')));
    previews = PreviewTable.withFile(() async => File(p.join(root.path, 'tv_previews.bin')));
  }

  final Directory root;
  final _FakeIndex index;
  final remote = _FakeRemote();
  final dateRemote = _DateRemote();
  late ThumbStore store;
  late PreviewTable previews;
  bool wifi = true;
  bool charging = false;
  bool busy = false;
  Completer<void>? tocGate;
  int tocCalls = 0;

  Directory get support => Directory(p.join(root.path, 'support'));
  File get lockFile => File(p.join(root.path, 'tv_maintenance.lock'));

  AutoPackService packer() => AutoPackService(
        index: index,
        remote: remote,
        store: store,
        previews: previews,
        stateStore: BackfillStateStore(() async => Directory(p.join(support.path, 'auto_pack'))),
        backfillStateStore: BackfillStateStore(() async => support),
        readToc: (m) async {
          tocCalls++;
          await tocGate?.future;
          return PackTocResult(messageId: m, packId: 'x', ids: const []);
        },
        workDir: () async => Directory(p.join(root.path, 'work_pack')),
        onPackApplied: (_, _) {},
      );

  BackfillService backfill() => BackfillService(
        index: index,
        remote: remote,
        codec: _Codec(),
        store: store,
        previews: previews,
        stateStore: BackfillStateStore(() async => support),
        workDir: () async => Directory(p.join(root.path, 'work_bf')),
        requireUnmetered: false,
        onPackApplied: (_, _) {},
      );

  CaptureDateRecoveryService dates() => CaptureDateRecoveryService(
        index: index,
        remote: dateRemote,
        stateStore: CaptureRecoveryStateStore(() async => support),
        requireUnmetered: false,
      );

  AutoMaintenanceService make({int maxBackfillChunks = 1, int datesChunk = 30}) => AutoMaintenanceService(
        packer: packer(),
        dates: dates(),
        backfill: backfill(),
        lock: MaintenanceLock(() async => lockFile),
        unmetered: () async => wifi,
        charging: () async => charging,
        userBusy: () => busy,
        datesChunk: datesChunk,
        backfillChunk: 50,
        maxBackfillChunks: maxBackfillChunks,
      );
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tv_maint_test');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  group('MaintenanceLock', () {
    test('one holder at a time; released or stale locks can be taken', () async {
      final file = File(p.join(root.path, 'l.lock'));
      var now = DateTime.utc(2026, 11, 12, 12);
      final a = MaintenanceLock(() async => file, now: () => now);
      final b = MaintenanceLock(() async => file, now: () => now);
      expect(await a.tryAcquire(), isTrue);
      expect(await b.tryAcquire(), isFalse);
      await a.release();
      expect(file.existsSync(), isFalse);
      expect(await b.tryAcquire(), isTrue);

      // b's process died without releasing: after staleAfter it is free.
      now = now.add(const Duration(minutes: 4));
      expect(await a.tryAcquire(), isTrue);
      await b.release(); // not b's anymore: the file stays
      expect(file.existsSync(), isTrue);
    });

    test('two concurrent acquirers: exactly one owner', () async {
      for (var round = 0; round < 20; round++) {
        final file = File(p.join(root.path, 'race$round.lock'));
        final locks = [for (var i = 0; i < 4; i++) MaintenanceLock(() async => file)];
        final got = await Future.wait(locks.map((l) => l.tryAcquire()));
        expect(got.where((g) => g), hasLength(1), reason: 'round $round');
        expect(locks.where((l) => l.isHeld), hasLength(1));
        // The holder is the one named in the file and can refresh.
        final owner = locks[got.indexOf(true)];
        await owner.refresh();
        expect(owner.isHeld, isTrue);
        await owner.release();
        expect(file.existsSync(), isFalse);
      }
    });

    test('concurrent takeover of a stale lock: exactly one owner', () async {
      final file = File(p.join(root.path, 'stale.lock'));
      final t0 = DateTime.utc(2026, 11, 12, 12);
      file.writeAsStringSync('dead-token ${t0.millisecondsSinceEpoch}');
      final later = t0.add(const Duration(minutes: 4));
      final a = MaintenanceLock(() async => file, now: () => later);
      final b = MaintenanceLock(() async => file, now: () => later);
      final got = await Future.wait([a.tryAcquire(), b.tryAcquire()]);
      expect(got.where((g) => g), hasLength(1));
    });

    test('a fresh lock of another holder is not taken', () async {
      final file = File(p.join(root.path, 'fresh.lock'));
      final now = DateTime.utc(2026, 11, 12, 12);
      file.writeAsStringSync('someone ${now.millisecondsSinceEpoch}');
      final a = MaintenanceLock(() async => file, now: () => now.add(const Duration(minutes: 1)));
      expect(await a.tryAcquire(), isFalse);
      expect(file.readAsStringSync(), startsWith('someone'));
    });
  });

  test('metered network: nothing runs', () async {
    final env = _Env(root, 10);
    env.wifi = false;
    env.charging = true;
    final r = await env.make().runOnce();
    expect(r.skipped, 'metered');
    expect(env.dateRemote.probed, isEmpty);
    expect(env.remote.serverThumbTargets, isEmpty);
    expect(env.lockFile.existsSync(), isFalse);
  });

  test('Wi-Fi only: packs and dates run, the backfill does not', () async {
    final env = _Env(root, 80);
    final r = await env.make().runOnce();
    expect(r.skipped, isNull);
    expect(r.datesProcessed, 30, reason: 'one chunk of capture dates');
    expect(env.dateRemote.probed, hasLength(30));
    expect(r.backfillChunks, 0);
    expect(env.remote.serverThumbTargets, isEmpty);
    expect(env.index.writes, 0, reason: 'no date found, no pack: nothing to write');
  });

  test('Wi-Fi + charging: one backfill chunk of 50, resumable, packs at the end', () async {
    final env = _Env(root, 120);
    env.charging = true;
    final first = await env.make().runOnce();
    expect(first.backfillChunks, 1);
    expect(first.backfillProduced, 50);
    expect(env.remote.serverThumbTargets.toSet(), hasLength(50));
    expect(env.remote.uploads, isEmpty, reason: 'no partial pack mid-way');
    expect(env.remote.fetched, isEmpty);

    // The next runs continue where it stopped; the last chunk packs the rest.
    await env.make().runOnce();
    final last = await env.make().runOnce();
    expect(last.backfillProduced, 20);
    expect(env.remote.serverThumbTargets, hasLength(120), reason: 'each item fetched once');
    final ids = env.remote.packedIds();
    expect(ids.toSet(), {for (var i = 0; i < 120; i++) _id(i)});
    expect(ids.toSet().length, ids.length);
    expect(env.index.index.thumbPacks, hasLength(1));

    // The auto-packer never packs the backfill's thumbnails a second time.
    final again = await env.make().runOnce();
    expect(again.packs, 0);
    expect(env.remote.uploads, hasLength(1));
  });

  test('user busy (upload queue, thumbnails on screen): skipped unless the queue just finished', () async {
    final env = _Env(root, 10);
    env.busy = true;
    expect((await env.make().runOnce()).skipped, 'busy');
    expect(env.dateRemote.probed, isEmpty);
    final r = await env.make().runOnce(queueJustFinished: true);
    expect(r.skipped, isNull);
    expect(r.backfillChunks, 0, reason: 'the backfill never competes with the user');
  });

  test('the lock prevents two maintenance jobs (and two packers) at once', () async {
    final env = _Env(root, 10);
    env.index.index = env.index.index.addThumbPack(
        ThumbPackRef(id: 'x', messageId: 5, count: 1, size: 1, createdAt: DateTime.utc(2026)));
    env.tocGate = Completer<void>();
    final a = env.make();
    final b = env.make();
    final first = a.runOnce();
    while (env.tocCalls == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(a.status.value.running, isTrue);
    final second = await b.runOnce();
    expect(second.skipped, 'locked');
    expect((await a.runOnce()).skipped, 'running');
    env.tocGate!.complete();
    expect((await first).skipped, isNull);
    expect(env.tocCalls, 1);
    expect(a.status.value.running, isFalse);
    expect(env.lockFile.existsSync(), isFalse);
  });

  test('capture-date chunks resume where the last one stopped', () async {
    final env = _Env(root, 25);
    final dates = env.dates();
    await dates.run(maxItems: 10);
    await env.dates().run(maxItems: 10);
    await env.dates().run(maxItems: 10);
    expect(env.dateRemote.probed, hasLength(25));
    expect(env.dateRemote.probed.toSet(), hasLength(25));
  });

  test('no manual maintenance UI is left', () {
    expect(File('lib/features/profile/screens/backfill_screen.dart').existsSync(), isFalse);
    final sheet = File('lib/features/profile/screens/account_sheet.dart').readAsStringSync();
    for (final word in ['BackfillScreen', 'Thumbnail backfill', 'Recuperar fechas', 'backfill_screen']) {
      expect(sheet.contains(word), isFalse, reason: word);
    }
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      expect(src.contains('BackfillScreen'), isFalse, reason: f.path);
      expect(src.contains('Recuperar fechas'), isFalse, reason: f.path);
    }
  });
}
