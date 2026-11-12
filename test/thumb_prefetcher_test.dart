import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/thumbnail/pack_installer.dart';
import 'package:tele_vault/core/thumbnail/preview_table.dart';
import 'package:tele_vault/core/thumbnail/server_thumb_batch.dart';
import 'package:tele_vault/core/thumbnail/thumb_prefetcher.dart';
import 'package:tele_vault/core/thumbnail/thumb_store.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tele_vault/models/thumb_pack_ref.dart';
import 'package:tv_core/codecs.dart';

Uint8List _jpeg(int tag) => Uint8List.fromList([0xFF, 0xD8, tag & 0xFF, (tag >> 8) & 0xFF, 0xFF, 0xD9]);

Uint8List _hash([int r = 120, int g = 60, int b = 200]) {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return PreviewCodec.encodeRgba(rgba, 8, 8)!;
}

FileItem _item(String id, {String mime = 'image/jpeg', int messageId = 1}) => FileItem(
      id: id,
      name: 'n_$id',
      folderId: null,
      totalSize: 10,
      mimeType: mime,
      createdAt: DateTime.utc(2026),
      parts: [FilePart(messageId: messageId, part: 0, size: 10)],
    );

ThumbRequest _cloud(int i, {String mime = 'image/jpeg'}) =>
    ThumbRequest(key: 'c$i', file: _item('c$i', mime: mime, messageId: 1000 + i));

ThumbRequest _device(int i) => ThumbRequest(key: 'd$i', assetId: 'asset$i');

Future<void> _eventually(bool Function() cond, {int ms = 5000, String? what}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

class _Env {
  _Env(this.dir) {
    store = ThumbStore.withDirectory(() async => dir);
    previews = PreviewTable.withFile(() async => File(p.join(dir.path, 'tv_previews.bin')));
  }
  final Directory dir;
  late final ThumbStore store;
  late final PreviewTable previews;

  // Fakes and their call logs.
  final deviceCalls = <String>[];
  final serverBatches = <List<String>>[];
  final fullCalls = <String>[];
  int installCalls = 0;

  Future<Uint8List?> Function(ThumbRequest r)? deviceImpl;
  Future<List<ServerThumbResult>> Function(List<ServerThumbTarget> t)? serverImpl;
  Future<PackInstallResult> Function(PackInstallArgs a)? installImpl;
  List<ThumbPackRef> discovered = const [];

  ThumbPrefetcher make({
    int deviceConcurrency = 2,
    List<Duration> backoff = const [Duration(milliseconds: 40), Duration(milliseconds: 80)],
  }) {
    return ThumbPrefetcher(
      store: store,
      previews: previews,
      deviceConcurrency: deviceConcurrency,
      backoff: backoff,
      previewFromJpeg: (_) async => _hash(),
      deviceThumb: (r) async {
        deviceCalls.add(r.key);
        final impl = deviceImpl;
        if (impl != null) return impl(r);
        await Future<void>.delayed(const Duration(milliseconds: 3));
        return _jpeg(r.key.hashCode);
      },
      serverThumbs: (targets) async {
        serverBatches.add([for (final t in targets) t.key]);
        final impl = serverImpl;
        if (impl != null) return impl(targets);
        return [for (final t in targets) ServerThumbResult.ok(t.key, _jpeg(t.messageId))];
      },
      fullThumb: (file) async {
        fullCalls.add(file.id);
        return _jpeg(77);
      },
      installPack: (args) async {
        installCalls++;
        final impl = installImpl;
        if (impl != null) return impl(args);
        return PackInstallResult(packId: args.packId, messageId: args.messageId);
      },
      discoverPacks: () async => discovered,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Env env;
  setUp(() async {
    env = _Env(await Directory.systemTemp.createTemp('thumb_prefetcher_test'));
  });
  tearDown(() async {
    await env.previews.flushForTesting();
    try {
      if (await env.dir.exists()) await env.dir.delete(recursive: true);
    } catch (_) {}
  });

  test('prioritized keys run first, newest request first; background waits for resume', () async {
    final pf = env.make(deviceConcurrency: 1);
    addTearDown(pf.dispose);
    final lib = [for (var i = 0; i < 6; i++) _device(i)];
    pf.pause();
    pf.updateLibrary(inFeedOrder: lib, packs: const []);
    pf.prioritize(lib[1]);
    pf.prioritize(lib[2]);
    pf.prioritize(lib[3]);

    await _eventually(() => env.deviceCalls.length >= 3, what: 'prioritized keys');
    await _settle();
    // Paused: nothing but the three prioritized keys was produced.
    expect(env.deviceCalls, ['d3', 'd2', 'd1']);

    pf.resume();
    await _eventually(() => env.store.has('d0') && env.store.has('d4') && env.store.has('d5'));
    // The rest follows in feed order, one at a time.
    expect(env.deviceCalls, ['d3', 'd2', 'd1', 'd0', 'd4', 'd5']);
    for (var i = 0; i < 6; i++) {
      expect(env.store.has('d$i'), isTrue);
    }
    // Previews were stored next to the thumbnails.
    expect(env.previews.hash('d0'), isNotNull);
  });

  test('a failure is retried after its backoff and never cached as "no thumbnail"', () async {
    var attempts = 0;
    env.deviceImpl = (r) async {
      attempts++;
      if (attempts <= 2) throw StateError('transient');
      return _jpeg(5);
    };
    final pf = env.make();
    addTearDown(pf.dispose);
    final r = _device(0);
    pf.updateLibrary(inFeedOrder: [r], packs: const []);

    // First call fails: the waiter gets null, but nothing remembers that.
    expect(await pf.fetch(r), isNull);
    expect(attempts, 1);
    // Still inside the backoff window: answered null again WITHOUT trying.
    expect(await pf.fetch(r), isNull);
    expect(attempts, 1);

    // The library entry keeps being retried by itself once the window passes:
    // second failure after 40 ms, success after the 80 ms backoff.
    await _eventually(() => env.store.has('d0'), what: 'retry after backoff');
    expect(attempts, 3);
    expect((await pf.fetch(r))!.existsSync(), isTrue);
  });

  test('retryFailedNow clears backoff immediately', () async {
    var attempts = 0;
    env.deviceImpl = (r) async {
      attempts++;
      if (attempts == 1) throw StateError('transient');
      return _jpeg(5);
    };
    final pf = env.make(backoff: const [Duration(hours: 1)]);
    addTearDown(pf.dispose);
    final r = _device(0);
    pf.updateLibrary(inFeedOrder: [r], packs: const []);
    expect(await pf.fetch(r), isNull);
    expect(attempts, 1);
    pf.retryFailedNow();
    await _eventually(() => env.store.has('d0'));
    expect(attempts, 2);
  });

  test('server thumbnails: batches of at most 50, prioritized keys lead', () async {
    final lib = [for (var i = 0; i < 120; i++) _cloud(i)];
    final pf = env.make();
    addTearDown(pf.dispose);
    pf.prioritize(lib[100]);
    pf.updateLibrary(inFeedOrder: lib, packs: const []);
    await _eventually(() => env.store.length == 120, what: 'all 120 thumbnails');
    expect(env.serverBatches.every((b) => b.length <= 50), isTrue);
    expect(env.serverBatches.first.first, 'c100');
    expect(env.serverBatches.expand((b) => b).toSet().length, 120);
    expect(env.fullCalls, isEmpty);
  });

  test('stage 4 (full download) never runs for non-prioritized keys', () async {
    env.serverImpl = (targets) async => [for (final t in targets) ServerThumbResult.none(t.key)];
    final lib = [_cloud(0), _cloud(1), _cloud(2), _cloud(3, mime: 'video/mp4')];
    final pf = env.make();
    addTearDown(pf.dispose);
    pf.updateLibrary(inFeedOrder: lib, packs: const []);
    await _eventually(() => env.serverBatches.isNotEmpty);
    await _settle(250);
    expect(env.fullCalls, isEmpty);
    expect(env.store.length, 0);

    // A tile asks for one image: only that one is downloaded.
    pf.prioritize(lib[1]);
    await _eventually(() => env.store.has('c1'), what: 'full download of c1');
    await _settle();
    expect(env.fullCalls, ['c1']);

    // A video with no server thumbnail has no source at all: null, no download.
    expect(await pf.fetch(lib[3]), isNull);
    expect(env.fullCalls, ['c1']);
  });

  test('an unusable full download marks the key noSource instead of retrying', () async {
    var fullTries = 0;
    final pf = ThumbPrefetcher(
      store: env.store,
      previews: env.previews,
      backoff: const [Duration(milliseconds: 10)],
      previewFromJpeg: (_) async => null,
      serverThumbs: (t) async => [for (final x in t) ServerThumbResult.none(x.key)],
      fullThumb: (_) async {
        fullTries++;
        return null; // undecodable
      },
      installPack: (a) async => PackInstallResult(packId: a.packId, messageId: a.messageId),
      discoverPacks: () async => const [],
    );
    addTearDown(pf.dispose);
    expect(await pf.fetch(_cloud(0)), isNull);
    await _settle(200);
    expect(fullTries, 1);
  });

  test('a failed server batch is retried and nothing is cached as missing', () async {
    var calls = 0;
    env.serverImpl = (targets) async {
      calls++;
      if (calls == 1) return [for (final t in targets) ServerThumbResult.error(t.key)];
      return [for (final t in targets) ServerThumbResult.ok(t.key, _jpeg(9))];
    };
    final pf = env.make();
    addTearDown(pf.dispose);
    final r = _cloud(0);
    pf.updateLibrary(inFeedOrder: [r], packs: const []);
    expect(await pf.fetch(r), isNull);
    await _eventually(() => env.store.has('c0'), what: 'retry after the failed batch');
    expect(calls, 2);
  });

  test('a device asset that is gone falls through to the cloud copy', () async {
    env.deviceImpl = (r) async => null;
    final both = ThumbRequest(key: 'c0', assetId: 'asset0', file: _item('c0', messageId: 1000));
    final pf = env.make();
    addTearDown(pf.dispose);
    pf.updateLibrary(inFeedOrder: [both], packs: const []);
    await _eventually(() => env.store.has('c0'), what: 'cloud fallback');
    expect(env.deviceCalls, ['c0']);
    expect(env.serverBatches, [
      ['c0']
    ]);
  });

  test('cancel completes a waiting fetch with null', () async {
    final gate = Completer<void>();
    env.deviceImpl = (r) async {
      await gate.future;
      return _jpeg(1);
    };
    final pf = env.make(deviceConcurrency: 1);
    addTearDown(pf.dispose);
    final a = _device(0);
    final b = _device(1);
    final fb = pf.fetch(b); // older request: waits behind the newer one (LIFO)
    final fa = pf.fetch(a);
    await _eventually(() => env.deviceCalls.isNotEmpty);
    pf.cancel('d1');
    expect(await fb, isNull);
    gate.complete();
    expect((await fa)!.existsSync(), isTrue);
    expect(env.deviceCalls, ['d0']); // b never started
  });

  test('without a usable store it is inert and never throws', () async {
    final dead = ThumbStore.withDirectory(() async => throw StateError('no path_provider'));
    final pf = ThumbPrefetcher(
      store: dead,
      previews: env.previews,
      deviceThumb: (_) async => _jpeg(1),
      discoverPacks: () async => const [],
    );
    addTearDown(pf.dispose);
    final r = _device(0);
    pf.updateLibrary(inFeedOrder: [r], packs: const []);
    pf.prioritize(r);
    expect(await pf.fetch(r).timeout(const Duration(seconds: 3)), isNull);
    expect(await pf.fetch(r), isNull);
  });

  group('packs', () {
    Uint8List buildPack(String packId, List<String> ids) => ThumbPackCodec.encode(
          packId: packId,
          createdAt: DateTime.utc(2026, 5),
          entries: [
            for (var i = 0; i < ids.length; i++)
              ThumbPackEntry(
                id: ids[i],
                jpeg: _jpeg(100 + i),
                width: 256,
                height: 192,
                preview: i == 0 ? PreviewCodec.toWire(_hash(10, 200, 10)) : null,
              ),
          ],
        );

    test('installPackWith writes valid entries, is idempotent and refuses bad packs', () async {
      final bytes = buildPack('pk1', ['a1', 'a2', 'a3']);
      final args = PackInstallArgs(messageId: 77, packId: 'pk1', dirPath: env.dir.path);
      final first = await installPackWith(args, download: (_) async => bytes);
      expect(first.ok, isTrue);
      expect(first.installedIds, ['a1', 'a2', 'a3']);
      expect(first.previews.keys, ['a1']);
      final f = File(p.join(env.dir.path, 'a2.jpg'));
      expect(f.readAsBytesSync(), _jpeg(101));
      final stamp = f.lastModifiedSync();
      expect(env.dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = await installPackWith(args, download: (_) async => bytes);
      expect(second.installedIds, first.installedIds);
      expect(f.lastModifiedSync(), stamp); // nothing rewritten

      // An existing (e.g. locally generated) thumbnail is kept.
      await File(p.join(env.dir.path, 'b1.jpg')).writeAsBytes(_jpeg(999));
      final third = await installPackWith(
        PackInstallArgs(messageId: 78, packId: 'pk2', dirPath: env.dir.path),
        download: (_) async => buildPack('pk2', ['b1']),
      );
      expect(third.installedIds, ['b1']);
      expect(File(p.join(env.dir.path, 'b1.jpg')).readAsBytesSync(), _jpeg(999));

      final bad = await installPackWith(args, download: (_) async => Uint8List.fromList(List.filled(40, 3)));
      expect(bad.ok, isFalse);
      expect(bad.permanent, isTrue);
      final net = await installPackWith(args, download: (_) async => throw const SocketException('x'));
      expect(net.ok, isFalse);
      expect(net.permanent, isFalse);
    });

    test('an unsafe entry id is never written outside the directory', () async {
      final bytes = ThumbPackCodec.encode(
        packId: 'pk',
        createdAt: DateTime.utc(2026),
        entries: [ThumbPackEntry(id: '../escape', jpeg: _jpeg(1), width: 1, height: 1)],
      );
      final res = await installPackWith(
        PackInstallArgs(messageId: 1, packId: 'pk', dirPath: env.dir.path),
        download: (_) async => bytes,
      );
      expect(res.installedIds, isEmpty);
      expect(res.corruptIds, ['../escape']);
      expect(File(p.join(env.dir.parent.path, 'escape.jpg')).existsSync(), isFalse);
    });

    test('packs fill the store before any server fetch and are installed only once', () async {
      final bytes = buildPack('pk1', ['c0', 'c1', 'c2']);
      env.installImpl = (a) => installPackWith(a, download: (_) async => bytes);
      final ref = ThumbPackRef(
        id: 'pk1',
        messageId: 500,
        count: 3,
        size: bytes.length,
        createdAt: DateTime.utc(2026, 5),
      );
      final lib = [_cloud(0), _cloud(1), _cloud(2)];
      final pf = env.make();
      addTearDown(pf.dispose);
      // The same pack from the index and from discovery counts once.
      env.discovered = [ref];
      pf.updateLibrary(inFeedOrder: lib, packs: [ref]);
      await _eventually(() => env.store.length == 3, what: 'pack install');
      await _settle();
      expect(env.installCalls, 1);
      expect(env.serverBatches, isEmpty);
      expect(env.previews.hash('c0'), isNotNull); // from the pack TOC
      expect(pf.appliedPacksForTesting, {'500': 'pk1'});
      final applied = jsonDecode(File(p.join(env.dir.path, '_packs_applied.json')).readAsStringSync());
      expect(applied, {
        'v': 1,
        'packs': {'500': 'pk1'}
      });

      // A new session over the same directory does not install it again.
      final env2 = _Env(env.dir);
      env2.installImpl = env.installImpl;
      env2.discovered = [ref];
      final pf2 = env2.make();
      addTearDown(pf2.dispose);
      pf2.updateLibrary(inFeedOrder: [...lib, _cloud(3)], packs: [ref]);
      await _eventually(() => env2.serverBatches.isNotEmpty, what: 'server batch after packs');
      expect(env2.installCalls, 0);
      expect(env2.serverBatches.expand((b) => b), ['c3']);
    });

    test('saving the applied packs keeps entries another writer put in the file', () async {
      final bytes = buildPack('pk1', ['c0']);
      env.installImpl = (a) async {
        // The backfill records a pack of its own while this install runs.
        File(p.join(env.dir.path, '_packs_applied.json'))
            .writeAsStringSync(jsonEncode({'v': 1, 'packs': {'777': 'bf'}}));
        return installPackWith(a, download: (_) async => bytes);
      };
      final ref = ThumbPackRef(
          id: 'pk1', messageId: 500, count: 1, size: bytes.length, createdAt: DateTime.utc(2026));
      final pf = env.make();
      addTearDown(pf.dispose);
      pf.updateLibrary(inFeedOrder: [_cloud(0)], packs: [ref]);
      await _eventually(() => pf.appliedPacksForTesting.containsKey('500'), what: 'pack install');
      await _settle();
      final applied = jsonDecode(File(p.join(env.dir.path, '_packs_applied.json')).readAsStringSync());
      expect(applied, {
        'v': 1,
        'packs': {'500': 'pk1', '777': 'bf'}
      });
      expect(pf.appliedPacksForTesting, {'500': 'pk1', '777': 'bf'});
      expect(File(p.join(env.dir.path, '_packs_applied.json.tmp')).existsSync(), isFalse);
    });

    test('markPackApplied keeps a pack the backfill produced from being installed', () async {
      final bytes = buildPack('pk1', ['c0']);
      env.installImpl = (a) => installPackWith(a, download: (_) async => bytes);
      final ref = ThumbPackRef(
          id: 'pk1', messageId: 500, count: 1, size: bytes.length, createdAt: DateTime.utc(2026));
      final pf = env.make();
      addTearDown(pf.dispose);
      pf.markPackApplied('pk1', 500);
      pf.updateLibrary(inFeedOrder: [_cloud(0)], packs: [ref]);
      await _eventually(() => env.serverBatches.isNotEmpty, what: 'server batch');
      expect(env.installCalls, 0);
    });

    test('a permanently bad pack is not retried and does not block the rest', () async {
      env.installImpl = (a) async => PackInstallResult(
            packId: a.packId,
            messageId: a.messageId,
            error: 'bad pack',
            permanent: true,
          );
      final ref = ThumbPackRef(
          id: 'pk', messageId: 9, count: 1, size: 1, createdAt: DateTime.utc(2026));
      final pf = env.make();
      addTearDown(pf.dispose);
      pf.updateLibrary(inFeedOrder: [_cloud(0)], packs: [ref]);
      await _eventually(() => env.store.has('c0'), what: 'server thumbnail after a bad pack');
      await _settle(300);
      expect(env.installCalls, 1);
    });

    test('a transiently failing pack backs off, then installs', () async {
      final bytes = buildPack('pk1', ['c0']);
      var tries = 0;
      env.installImpl = (a) {
        tries++;
        if (tries == 1) {
          return Future.value(PackInstallResult(
              packId: a.packId, messageId: a.messageId, error: 'download failed'));
        }
        return installPackWith(a, download: (_) async => bytes);
      };
      final ref = ThumbPackRef(
          id: 'pk1', messageId: 3, count: 1, size: 1, createdAt: DateTime.utc(2026));
      final pf = env.make();
      addTearDown(pf.dispose);
      pf.updateLibrary(inFeedOrder: [_cloud(0)], packs: [ref]);
      await _eventually(() => pf.appliedPacksForTesting.isNotEmpty, what: 'pack retry');
      expect(tries, 2);
      expect(env.store.has('c0'), isTrue);
    });
  });
}
