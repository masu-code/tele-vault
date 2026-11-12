import 'dart:convert';

import 'package:test/test.dart';
import 'package:tv_core/models.dart';

void main() {
  // JSON exactly as the pre-T3.1 app wrote it (same key order).
  const oldJson =
      '{"version":1,'
      '"folders":[{"id":"f1","name":"Docs","parent_id":null}],'
      '"files":[{"id":"a","name":"x.jpg","folder_id":"f1","total_size":10,'
      '"mime_type":"image/jpeg","created_at":"2026-06-19T12:00:00.000Z",'
      '"parts":[{"message_id":5,"part":0,"size":10}],"archived":false}],'
      '"albums":[{"id":"al","name":"Trip","file_ids":["a"],'
      '"created_at":"2026-06-19T12:00:00.000Z"}]}';

  group('backward compatible JSON', () {
    test('old JSON round-trips byte-identically', () {
      expect(FileIndex.decode(oldJson).encode(), oldJson);
    });

    test('old JSON has no preview, packs or extra', () {
      final idx = FileIndex.decode(oldJson);
      expect(idx.files.single.preview, isNull);
      expect(idx.files.single.extra, isEmpty);
      expect(idx.thumbPacks, isEmpty);
      expect(idx.extra, isEmpty);
    });

    test('new keys are omitted when null/empty', () {
      final json = FileIndex.decode(oldJson).toJson();
      expect(json.containsKey('thumb_packs'), isFalse);
      expect((json['files'] as List).single.containsKey('preview'), isFalse);
    });

    test('preview and thumb_packs round-trip', () {
      final idx = FileIndex.decode(oldJson)
          .withPreviews({'a': 'th1:AAEC'}).addThumbPack(ThumbPackRef(
        id: 'p1',
        messageId: 99,
        count: 3,
        size: 1234,
        createdAt: DateTime.utc(2026, 11, 11, 10, 30),
      ));
      final raw = idx.encode();
      final back = FileIndex.decode(raw);
      expect(back.files.single.preview, 'th1:AAEC');
      expect(back.thumbPacks.single.messageId, 99);
      expect(back.thumbPacks.single.createdAt, DateTime.utc(2026, 11, 11, 10, 30));
      expect(back.encode(), raw);
      // preview comes right after the known keys of the item.
      expect(raw, contains('"archived":false,"preview":"th1:AAEC"}'));
      expect(raw, contains('"thumb_packs":[{"id":"p1","message_id":99,'
          '"count":3,"size":1234,"created_at":"2026-11-11T10:30:00.000Z","v":1}]'));
    });

    test('unknown keys survive on file and index, after the known keys', () {
      const raw =
          '{"version":1,"folders":[],'
          '"files":[{"id":"a","name":"x","folder_id":null,"total_size":1,'
          '"mime_type":"image/png","created_at":"2026-06-19T12:00:00.000Z",'
          '"parts":[],"archived":true,"future":{"k":[1,2]}}],'
          '"albums":[],"zzz":7}';
      final idx = FileIndex.decode(raw);
      expect(idx.files.single.extra, {'future': {'k': [1, 2]}});
      expect(idx.extra, {'zzz': 7});
      expect(idx.encode(), raw);
      // Survive typical mutations too.
      final mutated = idx
          .renameFile('a', 'y')
          .archiveFiles([]).addFolder(const Folder(id: 'n', name: 'n', parentId: null));
      final out = jsonDecode(mutated.encode()) as Map<String, dynamic>;
      expect(out['zzz'], 7);
      expect((out['files'] as List).single['future'], {'k': [1, 2]});
    });

    test('known keys win over extra', () {
      final item = FileItem.fromJson(jsonDecode(
              '{"id":"a","name":"x","folder_id":null,"total_size":1,'
              '"mime_type":"m","created_at":"2026-06-19T12:00:00.000Z",'
              '"parts":[],"archived":false}')
          as Map<String, dynamic>);
      final forced = FileItem(
        id: item.id,
        name: 'real',
        folderId: null,
        totalSize: 1,
        mimeType: 'm',
        createdAt: item.createdAt,
        parts: const [],
        extra: const {'name': 'fake', 'other': 1},
      );
      final json = forced.toJson();
      expect(json['name'], 'real');
      expect(json['other'], 1);
    });
  });

  group('FileItem.copyWith preview', () {
    final item = FileItem(
      id: 'a',
      name: 'x',
      folderId: null,
      totalSize: 1,
      mimeType: 'image/png',
      createdAt: DateTime.utc(2026),
      parts: const [],
      preview: 'th1:AA',
    );
    test('omitted keeps, null clears, value sets', () {
      expect(item.copyWith(name: 'y').preview, 'th1:AA');
      expect(item.copyWith(preview: null).preview, isNull);
      expect(item.copyWith(preview: 'th1:BB').preview, 'th1:BB');
    });
  });

  group('FileIndex helpers', () {
    FileItem f(String id, {String? preview}) => FileItem(
          id: id,
          name: id,
          folderId: null,
          totalSize: 1,
          mimeType: 'image/png',
          createdAt: DateTime.utc(2026),
          parts: const [],
          preview: preview,
        );
    ThumbPackRef pack(int mid, String id) => ThumbPackRef(
        id: id, messageId: mid, count: 1, size: 1, createdAt: DateTime.utc(2026));

    test('merge unions packs by messageId and keeps earlier preview', () {
      final a = FileIndex(files: [f('1', preview: 'th1:A')], thumbPacks: [pack(1, 'p')]);
      final b = FileIndex(
          files: [f('1'), f('2')], thumbPacks: [pack(1, 'p'), pack(2, 'q')]);
      final m = FileIndex.merge([a, b]);
      expect(m.files.firstWhere((x) => x.id == '1').preview, 'th1:A');
      expect(m.thumbPacks.map((p) => p.messageId), [1, 2]);
    });

    test('merge: a later non-null preview wins', () {
      final a = FileIndex(files: [f('1', preview: 'th1:A')]);
      final b = FileIndex(files: [f('1', preview: 'th1:B')]);
      expect(FileIndex.merge([a, b]).files.single.preview, 'th1:B');
    });

    test('withPreviews respects overwrite and returns this when unchanged', () {
      final idx = FileIndex(files: [f('1', preview: 'th1:A'), f('2')]);
      final kept = idx.withPreviews({'1': 'th1:X', '2': 'th1:Y', 'zz': 'th1:Z'});
      expect(kept.files[0].preview, 'th1:A');
      expect(kept.files[1].preview, 'th1:Y');
      final over = idx.withPreviews({'1': 'th1:X'}, overwrite: true);
      expect(over.files[0].preview, 'th1:X');
      expect(identical(idx.withPreviews({'1': 'th1:A'}), idx), isTrue);
      expect(identical(idx.withPreviews({}), idx), isTrue);
    });

    test('addThumbPack dedupes by messageId', () {
      final idx = FileIndex().addThumbPack(pack(7, 'a')).addThumbPack(pack(7, 'b'));
      expect(idx.thumbPacks, hasLength(1));
      expect(idx.thumbPacks.single.id, 'b');
      expect(idx.addThumbPack(pack(8, 'c')).thumbPacks, hasLength(2));
    });
  });
}
