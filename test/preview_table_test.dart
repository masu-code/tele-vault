import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/thumbnail/preview_table.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tv_core/codecs.dart';

Uint8List _hashOf(int r, int g, int b) {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba[i] = r;
    rgba[i + 1] = g;
    rgba[i + 2] = b;
    rgba[i + 3] = 255;
  }
  return PreviewCodec.encodeRgba(rgba, 8, 8)!;
}

FileItem _item(String id, {String? preview}) => FileItem(
      id: id,
      name: 'n',
      folderId: null,
      totalSize: 1,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      parts: const [FilePart(messageId: 1, part: 0, size: 1)],
      preview: preview,
    );

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('preview_table_test');
    file = File(p.join(dir.path, 'tv_previews.bin'));
  });
  final tables = <PreviewTable>[];
  tearDown(() async {
    for (final t in tables) {
      await t.flushForTesting();
    }
    tables.clear();
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });

  PreviewTable table() {
    final t = PreviewTable.withFile(() async => file);
    tables.add(t);
    return t;
  }

  test('put, hash and average colour', () async {
    final t = table();
    await t.init();
    expect(t.hash('a'), isNull);
    expect(t.averageArgb('a'), isNull);
    t.put('a', _hashOf(200, 20, 30));
    expect(t.hash('a'), _hashOf(200, 20, 30));
    final argb = t.averageArgb('a')!;
    expect((argb >> 16) & 0xFF, closeTo(200, 4));
    expect((argb >> 8) & 0xFF, closeTo(20, 4));
    expect(argb & 0xFF, closeTo(30, 4));
    // The memoised colour follows an overwrite.
    t.put('a', _hashOf(10, 10, 240));
    expect(t.averageArgb('a')! & 0xFF, closeTo(240, 4));
  });

  test('invalid input is ignored', () async {
    final t = table();
    await t.init();
    t.put('', _hashOf(1, 2, 3));
    t.put('k', Uint8List(0));
    t.put('k', Uint8List.fromList([1, 2, 3]));
    t.put('x' * 300, _hashOf(1, 2, 3));
    expect(t.length, 0);
    await t.flushForTesting();
    expect(file.existsSync() ? file.lengthSync() : 0, 0);
  });

  test('persists across a restart; the last record of a key wins', () async {
    final t = table();
    await t.init();
    t.put('a', _hashOf(255, 0, 0));
    t.put('b', _hashOf(0, 255, 0));
    t.put('a', _hashOf(0, 0, 255));
    await t.flushForTesting();

    final t2 = table();
    await t2.init();
    expect(t2.length, 2);
    expect(t2.hash('a'), _hashOf(0, 0, 255));
    expect(t2.hash('b'), _hashOf(0, 255, 0));
  });

  test('a torn last record is cut off so later appends stay aligned', () async {
    final t = table();
    await t.init();
    t.put('a', _hashOf(255, 0, 0));
    await t.flushForTesting();
    final good = file.lengthSync();
    await file.writeAsBytes([5, 0x61, 0x62], mode: FileMode.append); // garbage tail

    final t2 = table();
    await t2.init();
    expect(t2.length, 1);
    expect(file.lengthSync(), good);
    t2.put('c', _hashOf(0, 255, 0));
    await t2.flushForTesting();

    final t3 = table();
    await t3.init();
    expect(t3.length, 2);
    expect(t3.hash('c'), _hashOf(0, 255, 0));
  });

  test('compacts when the file is more than twice the live data', () async {
    final t = table();
    await t.init();
    final colours = [for (var i = 0; i < 40; i++) _hashOf(i * 6, 255 - i * 6, 30)];
    for (var round = 0; round < 40; round++) {
      for (var k = 0; k < 40; k++) {
        t.put('key$k', colours[(k + round) % 40]);
      }
    }
    await t.flushForTesting();
    final live = 40 * (1 + 'key10'.length + 1 + colours.first.length);
    expect(file.lengthSync(), lessThan(live * 3));

    final t2 = table();
    await t2.init();
    expect(t2.length, 40);
    expect(t2.hash('key7'), colours[(7 + 39) % 40]);
  });

  test('importFromIndex reads FileItem.preview and skips what it has', () async {
    final h1 = _hashOf(90, 90, 200);
    final t = table();
    await t.init();
    t.importFromIndex([
      _item('f1', preview: PreviewCodec.toWire(h1)),
      _item('f2'),
      _item('f3', preview: 'th1:%%%not-base64'),
    ]);
    expect(t.hash('f1'), h1);
    expect(t.hash('f2'), isNull);
    expect(t.hash('f3'), isNull);
    await t.flushForTesting();
    final size = file.lengthSync();
    t.importFromIndex([_item('f1', preview: PreviewCodec.toWire(h1))]);
    await t.flushForTesting();
    expect(file.lengthSync(), size); // unchanged: nothing appended
  });

  test('puts made before init survive loading the file', () async {
    final first = table();
    await first.init();
    first.put('a', _hashOf(255, 0, 0));
    await first.flushForTesting();

    final t = table();
    t.put('a', _hashOf(0, 0, 255)); // before init: newer than the file
    await t.init();
    expect(t.hash('a'), _hashOf(0, 0, 255));
    await t.flushForTesting();
    final reloaded = table();
    await reloaded.init();
    expect(reloaded.hash('a'), _hashOf(0, 0, 255));
  });

  test('without a file location it works in memory and never throws', () async {
    final t = PreviewTable.withFile(() async => throw StateError('no path_provider'));
    await t.init();
    t.put('a', _hashOf(1, 2, 3));
    await t.flushForTesting();
    expect(t.hash('a'), _hashOf(1, 2, 3));
  });
}
