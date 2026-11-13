import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/thumbnail/auto_pack_service.dart';
import 'package:tele_vault/core/thumbnail/backfill_service.dart';
import 'package:tele_vault/core/thumbnail/backfill_state.dart';
import 'package:tele_vault/core/thumbnail/pack_coverage.dart';
import 'package:tele_vault/core/thumbnail/pack_installer.dart';
import 'package:tele_vault/core/thumbnail/preview_table.dart';
import 'package:tele_vault/core/thumbnail/thumb_store.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tele_vault/models/thumb_pack_ref.dart';
import 'package:tv_core/codecs.dart';

final Uint8List _thumb = () {
  final im = img.Image(width: 8, height: 6);
  img.fill(im, color: img.ColorRgb8(120, 40, 90));
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}();

String _id(int i) => 'i${i.toString().padLeft(5, '0')}';

FileIndex _library(int n) => FileIndex(files: [
      for (var i = 0; i < n; i++)
        FileItem(
          id: _id(i),
          name: 'secret_name_$i.jpg',
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

class _Upload {
  _Upload(this.packId, this.messageId, this.bytes);
  final String packId;
  final int messageId;
  final Uint8List bytes;
}

class _FakeRemote implements PackRemote {
  final uploads = <_Upload>[];
  int nextMessageId = 500000;
  int crashAfterSend = 0;

  @override
  Future<int> uploadPack(String path, String packId) async {
    final bytes = await File(path).readAsBytes();
    final id = nextMessageId++;
    uploads.add(_Upload(packId, id, bytes));
    if (crashAfterSend > 0) {
      crashAfterSend--;
      throw const SocketException('connection lost');
    }
    return id;
  }

  @override
  Future<ThumbPackRef?> findPack(String packId) async {
    for (final u in uploads) {
      if (u.packId == packId) {
        return ThumbPackRef(id: packId, messageId: u.messageId, count: 0, size: u.bytes.length, createdAt: DateTime.utc(2026));
      }
    }
    return null;
  }

  List<String> packedIds() => [
        for (final u in uploads)
          for (final e in ThumbPackCodec.decode(u.bytes).entries) e.id,
      ];
}

class _Env {
  _Env(this.root, int items) : index = _FakeIndex(_library(items)) {
    restart();
  }

  final Directory root;
  final _FakeIndex index;
  final remote = _FakeRemote();
  late ThumbStore store;
  late PreviewTable previews;
  final tocCalls = <int>[];
  PackTocResult Function(int messageId)? toc;
  DateTime thumbTime = DateTime.utc(2026, 11, 12, 11);
  final DateTime now = DateTime.utc(2026, 11, 12, 12);
  final applied = <(String, int)>[];
  var _packSeq = 0;

  Directory get storeDir => Directory(p.join(root.path, 'thumbs'));
  Directory get support => Directory(p.join(root.path, 'support'));

  void restart() {
    store = ThumbStore.withDirectory(() async => storeDir);
    previews = PreviewTable.withFile(() async => File(p.join(root.path, 'tv_previews.bin')));
  }

  Future<void> seedThumbs(Iterable<int> which) async {
    await store.init();
    for (final i in which) {
      expect(await store.put(_id(i), _thumb), isTrue);
    }
  }

  AutoPackService make() => AutoPackService(
        index: index,
        remote: remote,
        store: store,
        previews: previews,
        stateStore: BackfillStateStore(() async => Directory(p.join(support.path, 'auto_pack'))),
        backfillStateStore: BackfillStateStore(() async => support),
        readToc: (m) async {
          tocCalls.add(m);
          final f = toc;
          if (f == null) throw StateError('no TOC expected');
          return f(m);
        },
        workDir: () async => Directory(p.join(root.path, 'work')),
        thumbTime: (_) async => thumbTime,
        now: () => now,
        newPackId: () => 'pack-${_packSeq++}',
        onPackApplied: (id, m) => applied.add((id, m)),
      );

  Map<String, dynamic> coverageFile() =>
      jsonDecode(File(p.join(storeDir.path, PackCoverage.fileName)).readAsStringSync())
          as Map<String, dynamic>;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tv_autopack_test');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('below 256 fresh candidates: nothing is packed', () async {
    final env = _Env(root, 255);
    await env.seedThumbs(List.generate(255, (i) => i));
    final r = await env.make().run();
    expect(r.outcome, AutoPackOutcome.belowThreshold);
    expect(r.candidates, 255);
    expect(env.remote.uploads, isEmpty);
    expect(env.index.writes, 0);
  });

  test('64 candidates older than 24 h make one pack; 63 do not', () async {
    final env = _Env(root, 64);
    env.thumbTime = env.now.subtract(const Duration(hours: 25));
    await env.seedThumbs(List.generate(63, (i) => i));
    expect((await env.make().run()).outcome, AutoPackOutcome.belowThreshold);
    expect(env.remote.uploads, isEmpty);

    await env.seedThumbs([63]);
    final r = await env.make().run();
    expect(r.outcome, AutoPackOutcome.packed);
    expect(r.packs, 1);
    expect(env.remote.packedIds(), hasLength(64));
  });

  test('64 fresh candidates (younger than 24 h): nothing is packed', () async {
    final env = _Env(root, 64);
    await env.seedThumbs(List.generate(64, (i) => i));
    expect((await env.make().run()).outcome, AutoPackOutcome.belowThreshold);
    expect(env.remote.uploads, isEmpty);
  });

  test('256 candidates: one pack, recorded in index, applied file and coverage', () async {
    final env = _Env(root, 300);
    await env.seedThumbs(List.generate(256, (i) => i));
    final r = await env.make().run();
    expect(r.packs, 1);
    expect(env.remote.uploads, hasLength(1));
    final u = env.remote.uploads.single;
    expect(env.index.index.thumbPacks.map((x) => x.messageId), [u.messageId]);
    expect(env.index.writes, 1, reason: 'one index write per pack');
    expect(env.applied, [(u.packId, u.messageId)]);
    final applied = jsonDecode(File(p.join(env.storeDir.path, '_packs_applied.json')).readAsStringSync());
    expect(applied['packs']['${u.messageId}'], u.packId);
    final cov = env.coverageFile()['packs'] as Map<String, dynamic>;
    expect((cov['${u.messageId}']['ids'] as List).length, 256);

    // A second run reads no TOC (own pack) and packs nothing more.
    final again = await env.make().run();
    expect(again.candidates, 0);
    expect(env.tocCalls, isEmpty);
    expect(env.remote.uploads, hasLength(1));
  });

  test('one pack per 512 thumbnails, at most 2 packs per run', () async {
    final env = _Env(root, 1300);
    await env.seedThumbs(List.generate(1300, (i) => i));
    final r = await env.make().run();
    expect(r.packs, 2);
    for (final u in env.remote.uploads) {
      expect(ThumbPackCodec.decode(u.bytes).entries, hasLength(512));
    }
    final ids = env.remote.packedIds();
    expect(ids.toSet().length, ids.length, reason: 'an id is in two packs');

    // The rest (276) waits for the next trigger.
    final next = await env.make().run();
    expect(next.packs, 1);
    expect(env.remote.packedIds().toSet(), {for (var i = 0; i < 1300; i++) _id(i)});
  });

  test('crash right after sendMedia: the pack is found by caption, not sent again', () async {
    final env = _Env(root, 300);
    await env.seedThumbs(List.generate(300, (i) => i));
    env.remote.crashAfterSend = 1;
    await expectLater(env.make().run(), throwsA(isA<SocketException>()));
    expect(env.remote.uploads, hasLength(1));
    expect(env.index.index.thumbPacks, isEmpty);

    env.restart();
    final r = await env.make().run();
    expect(r.packs, 1);
    expect(env.remote.uploads, hasLength(1), reason: 'no duplicate pack');
    expect(env.index.index.thumbPacks.single.messageId, env.remote.uploads.single.messageId);
  });

  test('items covered by an index pack (TOC), the backfill state or own packs are excluded', () async {
    final env = _Env(root, 400);
    await env.seedThumbs(List.generate(400, (i) => i));
    // Another device's pack holds i00000..i00099.
    env.index.index = env.index.index.addThumbPack(
        ThumbPackRef(id: 'other', messageId: 777, count: 100, size: 1, createdAt: DateTime.utc(2026)));
    env.toc = (m) => PackTocResult(messageId: m, packId: 'other', ids: [for (var i = 0; i < 100; i++) _id(i)]);
    // The backfill job is waiting to pack i00100..i00149.
    final bfStore = BackfillStateStore(() async => env.support);
    final bf = BackfillState();
    for (var i = 100; i < 150; i++) {
      bf.produced[_id(i)] = 500;
    }
    await bfStore.save(bf);

    final r = await env.make().run();
    expect(env.tocCalls, [777]);
    expect(r.candidates, 250);
    expect(r.outcome, AutoPackOutcome.belowThreshold);
    expect(env.remote.uploads, isEmpty);

    // Coverage is cached: the TOC is read once per pack per device.
    expect(env.coverageFile()['packs']['777']['id'], 'other');
    await env.make().run();
    expect(env.tocCalls, [777]);
  });

  test('a TOC that cannot be read (network, FLOOD_WAIT): nothing is packed, retried next run', () async {
    final env = _Env(root, 700);
    await env.seedThumbs(List.generate(700, (i) => i));
    env.index.index = env.index.index.addThumbPack(
        ThumbPackRef(id: 'other', messageId: 777, count: 100, size: 1, createdAt: DateTime.utc(2026)));
    env.toc = (m) => PackTocResult(messageId: m, error: 'read failed: FLOOD_WAIT');
    final r = await env.make().run();
    expect(r.outcome, AutoPackOutcome.coverageUnknown);
    expect(env.remote.uploads, isEmpty);
    expect(File(p.join(env.storeDir.path, PackCoverage.fileName)).existsSync(), isFalse);

    // A thrown read is unknown too.
    env.toc = (m) => throw const SocketException('offline');
    expect((await env.make().run()).outcome, AutoPackOutcome.coverageUnknown);
    expect(env.remote.uploads, isEmpty);

    env.toc = (m) => PackTocResult(messageId: m, packId: 'other', ids: [for (var i = 0; i < 100; i++) _id(i)]);
    final ok = await env.make().run();
    expect(ok.candidates, 600);
    expect(ok.packs, 1, reason: '512, then 88 fresh ones wait');
    expect(env.remote.packedIds().where((id) => int.parse(id.substring(1)) < 100), isEmpty);
  });

  test('a pack that can never be read covers nothing (and is not read again)', () async {
    final env = _Env(root, 300);
    await env.seedThumbs(List.generate(300, (i) => i));
    env.index.index = env.index.index.addThumbPack(
        ThumbPackRef(id: 'gone', messageId: 778, count: 10, size: 1, createdAt: DateTime.utc(2026)));
    env.toc = (m) => PackTocResult(messageId: m, error: 'no pack document', permanent: true);
    final r = await env.make().run();
    expect(r.candidates, 300);
    expect(r.packs, 1);
    await env.make().run();
    expect(env.tocCalls, [778]);
  });

  test('the index is written only through BackfillIndexAccess.write (applyAndSave in the app)', () {
    for (final path in const [
      'lib/core/thumbnail/auto_pack_service.dart',
      'lib/core/thumbnail/pack_publisher.dart',
      'lib/core/thumbnail/pack_coverage.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('IndexService.instance'), isFalse, reason: path);
      expect(src.contains('index/index_service.dart'), isFalse, reason: path);
      expect(src.contains('applyAndSave'), isFalse, reason: path);
    }
    final provider = File('lib/features/profile/providers/maintenance_provider.dart').readAsStringSync();
    expect(provider.contains('.applyAndSave(mutate)'), isTrue);
  });

  group('readPackTocWith', () {
    Uint8List pack(int n) => ThumbPackCodec.encode(
          packId: 'p1',
          createdAt: DateTime.utc(2026),
          entries: [
            for (var i = 0; i < n; i++) ThumbPackEntry(id: _id(i), jpeg: _thumb, width: 8, height: 6),
          ],
        );

    test('reads only header + TOC windows, never the whole pack', () async {
      final bytes = pack(512);
      final reads = <(int, int)>[];
      final r = await readPackTocWith(1, open: (_) async => (
            size: bytes.length,
            read: (int offset, int limit) async {
              reads.add((offset, limit));
              final end = offset + limit > bytes.length ? bytes.length : offset + limit;
              return Uint8List.sublistView(bytes, offset, end);
            },
          ));
      expect(r.ok, isTrue);
      expect(r.packId, 'p1');
      expect(r.ids, hasLength(512));
      final read = reads.fold<int>(0, (s, x) => s + x.$2);
      expect(read, lessThan(bytes.length));
      for (final (o, l) in reads) {
        expect(o % 4096, 0);
        expect(1024 * 1024 % l, 0);
      }
    });

    test('a failed read is retryable; a non-pack is permanent', () async {
      final failed = await readPackTocWith(1, open: (_) async => (
            size: 100000,
            read: (int o, int l) async => throw const SocketException('x'),
          ));
      expect(failed.ok, isFalse);
      expect(failed.permanent, isFalse);

      final junk = Uint8List(5000);
      final bad = await readPackTocWith(1, open: (_) async => (
            size: junk.length,
            read: (int o, int l) async => junk,
          ));
      expect(bad.ok, isFalse);
      expect(bad.permanent, isTrue);
    });
  });

  test('owned sources: no message deletion, no names or paths in logs', () {
    const files = [
      'lib/core/thumbnail/auto_pack_service.dart',
      'lib/core/thumbnail/auto_maintenance_service.dart',
      'lib/core/thumbnail/pack_publisher.dart',
      'lib/core/thumbnail/pack_coverage.dart',
      'lib/core/thumbnail/pack_installer.dart',
      'lib/core/thumbnail/backfill_service.dart',
      'lib/features/profile/providers/maintenance_provider.dart',
    ];
    final forbidden = ['delete' 'Messages', 'delete' 'History', 'edit' 'Message('];
    for (final path in files) {
      final src = File(path).readAsStringSync();
      for (final word in forbidden) {
        expect(src.contains(word), isFalse, reason: '$path contains $word');
      }
      for (final line in const LineSplitter().convert(src)) {
        final logs = line.contains('print(') || line.contains('_log(');
        if (!logs) continue;
        for (final word in ['.name', 'path', 'caption', 'fileName']) {
          expect(line.contains(word), isFalse, reason: '$path: $line');
        }
      }
    }
  });
}
