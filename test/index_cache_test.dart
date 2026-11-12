import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/index/index_cache.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

FileItem _file(String id) => FileItem(
      id: id,
      name: 'n_$id',
      folderId: null,
      totalSize: 1,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      parts: const [FilePart(messageId: 1, part: 0, size: 1)],
    );

Uint8List _bytes(FileIndex i) => Uint8List.fromList(utf8.encode(i.encode()));

void main() {
  late Directory dir;
  late IndexCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('index_cache_test');
    cache = IndexCache.inDirectory(dir);
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('empty directory reads as no cache', () async {
    expect(await cache.read(), isNull);
  });

  test('write then read round-trips bytes, ids and account', () async {
    final index = FileIndex(files: [_file('a'), _file('b')]);
    final bytes = _bytes(index);
    await cache.write(bytes, messageId: 7, documentId: 123, account: 99);
    final c = await cache.read();
    expect(c, isNotNull);
    expect(c!.bytes, bytes);
    expect(c.index.encode(), index.encode());
    expect(c.messageId, 7);
    expect(c.documentId, 123);
    expect(c.account, 99);
    expect(c.legacy, isFalse);
    final meta = jsonDecode(await File(p.join(dir.path, IndexCache.metaName)).readAsString())
        as Map<String, dynamic>;
    expect(meta.keys, containsAll(['message_id', 'document_id', 'saved_at']));
  });

  test('legacy cache keeps a null document id', () async {
    await cache.write(_bytes(FileIndex()), messageId: 3, documentId: null, legacy: true);
    final c = await cache.read();
    expect(c!.legacy, isTrue);
    expect(c.documentId, isNull);
  });

  test('bytes that do not match the meta (two writers interleaved) are rejected', () async {
    await cache.write(_bytes(FileIndex(files: [_file('a')])), messageId: 7, documentId: 1);
    // Another writer replaced the bytes but not (yet) the meta.
    await File(p.join(dir.path, IndexCache.cacheName))
        .writeAsBytes(_bytes(FileIndex(files: [_file('z')])));
    expect(await cache.read(), isNull);
  });

  test('corrupt json is rejected, never thrown', () async {
    await cache.write(Uint8List.fromList(utf8.encode('{not json')), messageId: 7, documentId: 1);
    expect(await cache.read(), isNull);
  });

  test('no temp files are left behind by a write', () async {
    await cache.write(_bytes(FileIndex()), messageId: 1, documentId: 2);
    final names = dir.listSync().map((e) => p.basename(e.path)).toList();
    expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
  });

  test('backups keep exact bytes and only the newest 20', () async {
    final written = <Uint8List>[];
    for (var i = 0; i < 25; i++) {
      final b = _bytes(FileIndex(files: [_file('f$i')]));
      written.add(b);
      await cache.backup(b, label: i.isEven ? null : 'unsaved');
      // Distinct millisecond stamps keep the order deterministic.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final files = await cache.listBackups();
    expect(files, hasLength(IndexCache.keepBackups));
    // Oldest five pruned; the rest are byte-identical and in order.
    for (var i = 0; i < files.length; i++) {
      expect(await files[i].readAsBytes(), written[i + 5]);
    }
    expect(files.where((f) => f.path.endsWith('-unsaved.json')), isNotEmpty);
  });

  test('two backups in the same millisecond do not overwrite each other', () async {
    await Future.wait([
      cache.backup(_bytes(FileIndex(files: [_file('x')]))),
      cache.backup(_bytes(FileIndex(files: [_file('y')]))),
    ]);
    expect(await cache.listBackups(), hasLength(2));
  });
}
