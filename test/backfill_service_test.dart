import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
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

Uint8List _jpeg(int seed) {
  final im = img.Image(width: 8, height: 6);
  img.fill(im, color: img.ColorRgb8(seed * 37 % 256, seed * 11 % 256, 90));
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}

final Uint8List _hash = () {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = 200;
    rgba[i + 1] = 80;
    rgba[i + 2] = 40;
    rgba[i + 3] = 255;
  }
  return PreviewCodec.encodeRgba(rgba, 8, 8)!;
}();

/// One test library item and how the fake Telegram answers for it.
class _Spec {
  const _Spec(this.id, this.mime, {this.exists = true, this.serverThumb = false, this.decodable = true});
  final String id;
  final String mime;
  final bool exists;
  final bool serverThumb;
  final bool decodable;
}

const _specs = <_Spec>[
  _Spec('s1', 'image/jpeg', serverThumb: true),
  _Spec('s2', 'image/jpeg', serverThumb: true),
  _Spec('s3', 'image/png', serverThumb: true),
  _Spec('v2', 'video/mp4', serverThumb: true),
  _Spec('d1', 'image/jpeg'),
  _Spec('d2', 'image/jpeg'),
  _Spec('d3', 'image/jpeg'),
  _Spec('d4', 'image/png'),
  _Spec('d5', 'image/jpeg'),
  _Spec('d6', 'image/jpeg'),
  _Spec('d7', 'image/jpeg'),
  _Spec('u1', 'image/jpeg', decodable: false), // engine cannot decode -> desktop
  _Spec('v1', 'video/mp4'), // no server thumb, no ffmpeg -> desktop
  _Spec('h1', 'image/heic'), // engine cannot decode -> desktop, no download
  _Spec('m1', 'image/jpeg', exists: false), // message gone
  _Spec('e1', 'image/jpeg'), // already has a thumbnail in the store
  _Spec('doc1', 'application/pdf'), // not media
];

const _produced = ['s1', 's2', 's3', 'v2', 'd1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7'];
const int _itemSize = 1000;

int _msgId(String id) => 1000 + _specs.indexWhere((s) => s.id == id);

FileIndex _library() => FileIndex(files: [
      for (final s in _specs)
        FileItem(
          id: s.id,
          name: 'secret_name_${s.id}.bin',
          folderId: null,
          totalSize: _itemSize,
          mimeType: s.mime,
          createdAt: DateTime.utc(2025, 1, 1),
          parts: [FilePart(messageId: _msgId(s.id), part: 0, size: _itemSize)],
        ),
    ]);

class _FakeIndex implements BackfillIndexAccess {
  _FakeIndex(this.index);
  FileIndex index;
  int writes = 0;
  int failNextWrites = 0;
  bool busy = false;

  @override
  FileIndex? current() => busy ? null : index;

  @override
  Future<FileIndex> write(FileIndex Function(FileIndex current) mutate) async {
    final next = mutate(index);
    if (identical(next, index)) return index;
    if (failNextWrites > 0) {
      failNextWrites--;
      throw Exception('index write failed');
    }
    writes++;
    index = FileIndex.decode(next.encode()); // what the remote would hold
    return index;
  }
}

class _Upload {
  _Upload(this.packId, this.messageId, this.bytes);
  final String packId;
  final int messageId;
  final Uint8List bytes;
}

class _FakeRemote implements BackfillRemote {
  final probes = <int>[];
  final fetched = <String>[];
  final originals = <File>[];
  final uploads = <_Upload>[];
  int installs = 0;
  int nextMessageId = 900000;

  /// Upload reaches Telegram, then the call fails (lost connection).
  int crashAfterSend = 0;

  /// Called right after an original is fetched (e.g. to pause the job).
  void Function(String id)? onFetched;

  _Spec _spec(int messageId) => _specs[messageId - 1000];

  @override
  Future<List<BackfillProbe>> probe(List<int> messageIds) async {
    probes.addAll(messageIds);
    return [
      for (final id in messageIds)
        BackfillProbe(id, exists: _spec(id).exists, hasServerThumb: _spec(id).serverThumb),
    ];
  }

  @override
  Future<List<ServerThumbResult>> serverThumbs(List<ServerThumbTarget> targets) async => [
        for (final t in targets)
          if (!_spec(t.messageId).exists)
            ServerThumbResult.error(t.key)
          else if (_spec(t.messageId).serverThumb)
            ServerThumbResult.ok(t.key, _jpeg(t.messageId))
          else
            ServerThumbResult.none(t.key),
      ];

  @override
  Future<BackfillOriginal> fetchOriginal(FileItem item, String workDir) async {
    await Directory(workDir).create(recursive: true);
    final f = File(p.join(workDir, 'original.bin'));
    await f.writeAsString(item.id);
    fetched.add(item.id);
    originals.add(f);
    onFetched?.call(item.id);
    return BackfillOriginal(f, owned: true);
  }

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
        return ThumbPackRef(
          id: packId,
          messageId: u.messageId,
          count: 0,
          size: u.bytes.length,
          createdAt: DateTime.utc(2026),
        );
      }
    }
    return null;
  }

  @override
  Future<PackInstallResult> installPack(PackInstallArgs args) {
    installs++;
    final u = uploads.firstWhere((u) => u.messageId == args.messageId);
    return installPackWith(args, download: (_) async => u.bytes);
  }

  /// Every pack entry id over all uploads (duplicates kept).
  List<String> packedIds() => [
        for (final u in uploads)
          for (final e in ThumbPackCodec.decode(u.bytes).entries) e.id,
      ];
}

class _FakeCodec implements BackfillCodec {
  bool ffmpeg = false;

  @override
  bool engineCanDecode(String mime) => mime == 'image/jpeg' || mime == 'image/png';

  @override
  Future<bool> ffmpegAvailable() async => ffmpeg;

  @override
  Future<EncodedThumb?> encodeImage(File file) async {
    final id = await file.readAsString();
    final spec = _specs.firstWhere((s) => s.id == id);
    if (!spec.decodable) return null;
    return EncodedThumb(_jpeg(_msgId(id)), 8, 6, _hash);
  }

  @override
  Future<EncodedThumb?> encodeWithFfmpeg(File file, String workDir) async {
    if (!ffmpeg) return null;
    final id = await file.readAsString();
    return EncodedThumb(_jpeg(_msgId(id)), 8, 6, _hash);
  }

  @override
  Future<Uint8List?> previewOf(Uint8List jpeg) async => _hash;
}

class _Env {
  _Env(this.root) {
    restart();
  }

  final Directory root;
  late ThumbStore store;
  late PreviewTable previews;
  final remote = _FakeRemote();
  final codec = _FakeCodec();

  /// Packs the service reported to the prefetcher as applied (packId, messageId).
  final appliedCalls = <(String, int)>[];
  late final index = _FakeIndex(_library());

  Directory get workDir => Directory(p.join(root.path, 'work'));
  Directory get storeDir => Directory(p.join(root.path, 'thumbs'));

  /// A new process: fresh in-memory stores over the same directories.
  void restart() {
    store = ThumbStore.withDirectory(() async => storeDir);
    previews = PreviewTable.withFile(() async => File(p.join(root.path, 'tv_previews.bin')));
  }

  BackfillService make({bool requireUnmetered = false, bool network = true}) => BackfillService(
        index: index,
        remote: remote,
        codec: codec,
        store: store,
        previews: previews,
        stateStore: BackfillStateStore(() async => Directory(p.join(root.path, 'support'))),
        workDir: () async => workDir,
        networkAllowed: () async => network,
        requireUnmetered: requireUnmetered,
        maxPackEntries: 4,
        serverBatchSize: 2,
        probeBatchSize: 5,
        onPackApplied: (packId, messageId) => appliedCalls.add((packId, messageId)),
      );

  Future<void> seedExistingThumb() async {
    await store.init();
    expect(await store.put('e1', _jpeg(1)), isTrue);
  }

  /// Files left in the work directory (originals must never survive).
  List<String> workFiles() => workDir.existsSync()
      ? [for (final e in workDir.listSync(recursive: true)) if (e is File) p.basename(e.path)]
      : const [];

  Map<String, dynamic> applied() =>
      jsonDecode(File(p.join(storeDir.path, '_packs_applied.json')).readAsStringSync())
          as Map<String, dynamic>;
}

void _expectComplete(_Env env) {
  final ids = env.remote.packedIds();
  expect(ids.toSet().length, ids.length, reason: 'an id is in two packs');
  expect(ids.toSet(), _produced.toSet());
  expect(env.index.index.thumbPacks.map((r) => r.messageId).toSet(),
      env.remote.uploads.map((u) => u.messageId).toSet());
  for (final f in env.index.index.files) {
    if (_produced.contains(f.id)) {
      expect(f.preview, isNotNull, reason: 'preview of ${f.id}');
    }
  }
  for (final o in env.remote.originals) {
    expect(o.existsSync(), isFalse, reason: 'original left behind');
  }
  expect(env.workFiles(), isEmpty);
}

void main() {
  late Directory root;
  late _Env env;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tv_backfill_test');
    env = _Env(root);
    await env.seedExistingThumb();
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  test('plan counts candidates and bytes without downloading or writing', () async {
    final plan = await env.make().plan();
    expect(plan.mediaTotal, 16);
    expect(plan.candidates, 15);
    expect(plan.serverThumbs, 4);
    expect(plan.imagesToDownload, 8); // d1-d7 + u1 (decodability is only known after download)
    expect(plan.videosToDownload, 0);
    expect(plan.needsDesktop, 2); // v1, h1
    expect(plan.missing, 1);
    expect(plan.bytesToDownload, 8 * _itemSize);
    expect(plan.packsToInstall, 0);
    expect(env.remote.fetched, isEmpty);
    expect(env.remote.uploads, isEmpty);
    expect(env.index.writes, 0);
  });

  test('run makes thumbnails, packs them, records index + applied, deletes originals', () async {
    final result = await env.make().run();
    expect(result.paused, isFalse);
    expect(result.produced, _produced.length);
    expect(env.remote.uploads, hasLength(3)); // 11 thumbs, 4 per pack
    _expectComplete(env);
    expect(result.needsDesktop, 3); // v1, h1, u1
    expect(result.failures.keys, ['m1']);
    expect(result.failures['m1']!.mime, 'image/jpeg');
    expect(env.remote.fetched.toSet(), {'d1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7', 'u1'});
    // Pack format 7.2: entries carry previews.
    for (final u in env.remote.uploads) {
      for (final e in ThumbPackCodec.decode(u.bytes).entries) {
        expect(e.preview, isNotNull);
        expect(env.store.has(e.id), isTrue);
      }
    }
    final packs = env.applied()['packs'] as Map<String, dynamic>;
    for (final u in env.remote.uploads) {
      expect(packs['${u.messageId}'], u.packId);
      expect(env.appliedCalls, contains((u.packId, u.messageId)));
    }

    // A second run does nothing new: no downloads, uploads or index writes.
    final writes = env.index.writes;
    final fetched = env.remote.fetched.length;
    env.restart();
    final again = await env.make().run();
    expect(again.produced, 0);
    expect(env.remote.uploads, hasLength(3));
    expect(env.remote.fetched, hasLength(fetched));
    expect(env.index.writes, writes);
    expect(again.failures['m1']!.attempts, 2);
  });

  test('resume after the index write failed: no second upload of that pack', () async {
    env.index.failNextWrites = 1;
    await expectLater(env.make().run(), throwsA(anything));
    expect(env.remote.uploads, hasLength(1));
    expect(env.index.index.thumbPacks, isEmpty);

    env.restart();
    final result = await env.make().run();
    expect(result.paused, isFalse);
    expect(env.remote.uploads, hasLength(3));
    _expectComplete(env);
  });

  test('resume after a crash right after sendMedia: the pack is found, not re-sent', () async {
    env.remote.crashAfterSend = 1;
    await expectLater(env.make().run(), throwsA(anything));
    expect(env.remote.uploads, hasLength(1));

    env.restart();
    await env.make().run();
    expect(env.remote.uploads, hasLength(3));
    expect(env.remote.uploads.map((u) => u.packId).toSet(), hasLength(3));
    _expectComplete(env);
  });

  test('pause stops starting work; the next run resumes without duplicates', () async {
    final service = env.make();
    env.remote.onFetched = (id) {
      if (id == 'd2') service.pause();
    };
    final first = await service.run();
    expect(first.paused, isTrue);
    expect(env.remote.fetched.length, lessThan(8));
    expect(env.workFiles(), isEmpty);

    env.remote.onFetched = null;
    env.restart();
    final second = await env.make().run();
    expect(second.paused, isFalse);
    _expectComplete(env);
    // Each original was downloaded once.
    expect(env.remote.fetched.toSet().length, env.remote.fetched.length);
  });

  test('a pack made elsewhere is installed first and its items are not redone', () async {
    // Another device packs d1 and d2.
    final other = ThumbPackCodec.encode(packId: 'other-pack', createdAt: DateTime.utc(2026), entries: [
      ThumbPackEntry(id: 'd1', jpeg: _jpeg(1), width: 8, height: 6, preview: PreviewCodec.toWire(_hash)),
      ThumbPackEntry(id: 'd2', jpeg: _jpeg(2), width: 8, height: 6, preview: PreviewCodec.toWire(_hash)),
    ]);
    env.remote.uploads.add(_Upload('other-pack', 777, other));
    env.index.index = env.index.index.addThumbPack(ThumbPackRef(
        id: 'other-pack', messageId: 777, count: 2, size: other.length, createdAt: DateTime.utc(2026)));

    final plan = await env.make().plan();
    expect(plan.packsToInstall, 1);
    expect(env.remote.installs, 0, reason: 'plan downloads nothing');

    await env.make().run();
    expect(env.remote.installs, 1);
    expect(env.remote.fetched, isNot(contains('d1')));
    expect(env.remote.fetched, isNot(contains('d2')));
    final ids = env.remote.packedIds();
    expect(ids.where((i) => i == 'd1'), hasLength(1));
    // d1/d2 lacked previews in the index: patched from the installed pack.
    final d1 = env.index.index.files.firstWhere((f) => f.id == 'd1');
    expect(d1.preview, isNotNull);
  });

  test('Android gate: no unmetered network, nothing happens', () async {
    await expectLater(
      env.make(requireUnmetered: true, network: false).run(),
      throwsA(isA<BackfillBlockedException>()),
    );
    expect(env.remote.probes, isEmpty);
    expect(env.remote.fetched, isEmpty);
  });

  test('index loading or saving: plan and run refuse', () async {
    env.index.busy = true;
    await expectLater(env.make().plan(), throwsA(isA<BackfillBlockedException>()));
    await expectLater(env.make().run(), throwsA(isA<BackfillBlockedException>()));
    expect(env.remote.fetched, isEmpty);
  });

  test('owned sources: no message deletion and no names or paths in logs', () {
    const files = [
      'lib/core/thumbnail/backfill_service.dart',
      'lib/core/thumbnail/backfill_state.dart',
      'lib/features/profile/providers/maintenance_provider.dart',
    ];
    final forbidden = 'delete' 'Messages';
    for (final path in files) {
      final src = File(path).readAsStringSync();
      expect(src.contains(forbidden), isFalse, reason: path);
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
