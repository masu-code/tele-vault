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

  group('backup retention', () {
    String name(DateTime t, int n) =>
        '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
        'T${t.hour.toString().padLeft(2, '0')}0000${n.toString().padLeft(3, '0')}Z-0000.json';

    test('keeps the newest 20 and the oldest backup of each of the last 7 days', () {
      final names = <String>[];
      // Days 1..10: three backups each, then a night of 30 saves on day 11.
      for (var d = 1; d <= 10; d++) {
        for (var h = 0; h < 3; h++) {
          names.add(name(DateTime.utc(2026, 11, d, h), 0));
        }
      }
      for (var i = 0; i < 30; i++) {
        names.add(name(DateTime.utc(2026, 11, 11, 1), i));
      }
      final del = IndexCache.backupsToDelete(names).toSet();
      final kept = names.where((n) => !del.contains(n)).toList();
      expect(kept.skip(kept.length - 20), names.skip(names.length - 20), reason: 'newest 20');
      // Days 5..11 (the last 7) keep their oldest; days 1..4 keep nothing extra.
      for (var d = 5; d <= 10; d++) {
        expect(kept, contains(name(DateTime.utc(2026, 11, d, 0), 0)), reason: 'day $d oldest');
      }
      expect(kept, contains(name(DateTime.utc(2026, 11, 11, 1), 0)));
      expect(kept.where((n) => n.startsWith('202611040') || n.startsWith('202611010')), isEmpty);
      expect(kept, hasLength(20 + 6 + 1));
      // The other backups of an old day are pruned.
      expect(del, contains(name(DateTime.utc(2026, 11, 7, 1), 0)));
    });

    test('nothing to delete under the cap; empty list is fine', () {
      expect(IndexCache.backupsToDelete(const []), isEmpty);
      final few = [for (var i = 0; i < 20; i++) name(DateTime.utc(2026, 11, 1), i)];
      expect(IndexCache.backupsToDelete(few), isEmpty);
    });

    test('a night of saves never rotates out yesterday', () async {
      final backups = Directory(p.join(dir.path, IndexCache.backupDirName))..createSync();
      final yesterday = [
        name(DateTime.utc(2026, 11, 10, 8), 1),
        name(DateTime.utc(2026, 11, 10, 9), 1),
      ];
      for (final n in yesterday) {
        File(p.join(backups.path, n)).writeAsBytesSync([1]);
      }
      for (var i = 0; i < 25; i++) {
        await cache.backup(_bytes(FileIndex(files: [_file('n$i')])));
      }
      final left = (await cache.listBackups()).map((f) => p.basename(f.path)).toList();
      // Yesterday's oldest copy survives the 25 new ones (only if it is within
      // 7 days of the newest backup, i.e. the clock is not far from Nov 2026).
      final newest = DateTime.now().toUtc();
      if (newest.difference(DateTime.utc(2026, 11, 10)).inDays < IndexCache.keepDays) {
        expect(left, contains(yesterday.first));
        expect(left, isNot(contains(yesterday.last)));
      }
    });
  });

  test('backups keep exact bytes and the newest 20 (plus the first of the day)', () async {
    final written = <Uint8List>[];
    for (var i = 0; i < 25; i++) {
      final b = _bytes(FileIndex(files: [_file('f$i')]));
      written.add(b);
      await cache.backup(b, label: i.isEven ? null : 'unsaved');
      // Distinct millisecond stamps keep the order deterministic.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final files = await cache.listBackups();
    // Newest 20 plus the oldest of the day (all 25 were written today; the
    // run crossing UTC midnight would add one more day's oldest).
    expect(files.length, anyOf(IndexCache.keepBackups + 1, IndexCache.keepBackups + 2));
    expect(await files.first.readAsBytes(), written[0]);
    final tail = files.skip(files.length - IndexCache.keepBackups).toList();
    for (var i = 0; i < tail.length; i++) {
      expect(await tail[i].readAsBytes(), written[i + 5]);
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
