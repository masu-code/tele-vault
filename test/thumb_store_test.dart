import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/thumbnail/thumb_store.dart';

Uint8List _jpeg([int extra = 3]) =>
    Uint8List.fromList([0xFF, 0xD8, ...List.filled(extra, 7), 0xFF, 0xD9]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThumbKey', () {
    test('sha1 matches the standard vectors', () {
      expect(ThumbKey.sha1Hex('abc'), 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(ThumbKey.sha1Hex(''), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect(
        ThumbKey.sha1Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '84983e441c3bd26ebaae4aa1f95129e5e54670f1',
      );
    });

    test('cloud id wins; device key has the documented shape', () {
      expect(ThumbKey.forEntry(fileId: 'abc-1', assetId: 'x', assetModifiedSec: 5), 'abc-1');
      final k = ThumbKey.forEntry(assetId: 'abc', assetModifiedSec: 1234);
      expect(k, 'a_a9993e364706816aba3e_1234');
      expect(ThumbKey.forEntry(assetId: 'abc'), 'a_a9993e364706816aba3e_0');
      expect(() => ThumbKey.forEntry(), throwsArgumentError);
    });

    test('isSafe refuses anything that could escape the directory', () {
      expect(ThumbKey.isSafe('3f2b8c1e-aaaa-bbbb-cccc-0123456789ab'), isTrue);
      expect(ThumbKey.isSafe('a_ab12_77'), isTrue);
      expect(ThumbKey.isSafe(''), isFalse);
      expect(ThumbKey.isSafe('../x'), isFalse);
      expect(ThumbKey.isSafe('a/b'), isFalse);
      expect(ThumbKey.isSafe(r'a\b'), isFalse);
      expect(ThumbKey.isSafe('a.jpg'), isFalse);
      expect(ThumbKey.isSafe('x' * 81), isFalse);
    });
  });

  group('ThumbStore', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('thumb_store_test'));
    tearDown(() async {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
    });

    ThumbStore store({int? maxBytes}) =>
        ThumbStore.withDirectory(() async => dir, maxBytes: maxBytes);

    test('init lists keys, drops *.tmp and 0-byte files, is idempotent', () async {
      await File(p.join(dir.path, 'one.jpg')).writeAsBytes(_jpeg());
      await File(p.join(dir.path, 'empty.jpg')).writeAsBytes([]);
      await File(p.join(dir.path, 'two.jpg.3.tmp')).writeAsBytes([1, 2, 3]);
      await File(p.join(dir.path, '_packs_applied.json')).writeAsString('{}');
      final s = store();
      expect(s.isReady, isFalse);
      await Future.wait([s.init(), s.init()]);
      expect(s.isReady, isTrue);
      expect(s.has('one'), isTrue);
      expect(s.has('empty'), isFalse);
      expect(s.length, 1);
      expect(File(p.join(dir.path, 'empty.jpg')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'two.jpg.3.tmp')).existsSync(), isFalse);
      expect(File(p.join(dir.path, '_packs_applied.json')).existsSync(), isTrue);
      expect(s.fileIfPresent('one')!.path, p.join(dir.path, 'one.jpg'));
      expect(s.fileIfPresent('nope'), isNull);
    });

    test('put validates, writes atomically and bumps revision', () async {
      final s = store();
      expect(await s.put('k1', _jpeg()), isTrue);
      expect(s.has('k1'), isTrue);
      expect(await s.fileIfPresent('k1')!.readAsBytes(), _jpeg());
      expect(dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);

      expect(await s.put('k2', Uint8List.fromList([1, 2, 3, 4, 5])), isFalse); // no SOI/EOI
      expect(await s.put('k3', Uint8List.fromList([0xFF, 0xD8, 1, 2, 3])), isFalse); // no EOI
      expect(await s.put('../evil', _jpeg()), isFalse);
      expect(await s.put('big', _jpeg(ThumbStore.maxJpegBytes)), isFalse);
      expect(s.has('k2') || s.has('k3') || s.has('big'), isFalse);

      final before = s.revision.value;
      expect(before, greaterThan(0));
      // Many puts in a burst coalesce into far fewer revision bumps.
      for (var i = 0; i < 20; i++) {
        await s.put('burst$i', _jpeg());
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(s.revision.value - before, lessThan(10));
      expect(s.revision.value, greaterThan(before));
    });

    test('put overwrites an existing thumbnail', () async {
      final s = store();
      await s.put('k', _jpeg(3));
      await s.put('k', _jpeg(9));
      expect(await s.fileIfPresent('k')!.readAsBytes(), _jpeg(9));
    });

    test('markPresent and reportCorrupt', () async {
      final s = store();
      await s.init();
      await File(p.join(dir.path, 'packed.jpg')).writeAsBytes(_jpeg());
      s.markPresent(['packed', '../bad']);
      expect(s.has('packed'), isTrue);
      expect(s.has('../bad'), isFalse);
      await s.reportCorrupt('packed');
      expect(s.has('packed'), isFalse);
      expect(File(p.join(dir.path, 'packed.jpg')).existsSync(), isFalse);
    });

    test('over budget: oldest device thumbnails are evicted, cloud ones kept', () async {
      final big = _jpeg(1000);
      final cloud = File(p.join(dir.path, 'cloud-1.jpg'))..writeAsBytesSync(big);
      final old = File(p.join(dir.path, 'a_old_1.jpg'))..writeAsBytesSync(big);
      final newer = File(p.join(dir.path, 'a_new_2.jpg'))..writeAsBytesSync(big);
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      newer.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
      final s = store(maxBytes: big.length * 2 + 10);
      await s.init();
      expect(s.has('cloud-1'), isTrue);
      expect(s.has('a_new_2'), isTrue);
      expect(s.has('a_old_1'), isFalse);
      expect(old.existsSync(), isFalse);
      expect(cloud.existsSync(), isTrue);
    });

    test('without a usable directory it stays inert', () async {
      final s = ThumbStore.withDirectory(() async => throw StateError('no path_provider'));
      await expectLater(s.init(), throwsA(isA<StateError>()));
      expect(s.isReady, isFalse);
      expect(s.has('x'), isFalse);
      expect(s.fileIfPresent('x'), isNull);
      expect(await s.put('x', _jpeg()), isFalse);
      await s.reportCorrupt('x'); // no throw
      s.markPresent(['x']);
    });
  });
}
