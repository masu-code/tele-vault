import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/models/album.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';
import 'package:tele_vault/models/folder.dart';

void main() {
  group('FileIndex serialization', () {
    final sample = FileIndex(
      folders: const [
        Folder(id: 'f1', name: 'Documents', parentId: null),
        Folder(id: 'f2', name: 'Reports', parentId: 'f1'),
      ],
      files: [
        FileItem(
          id: 'file1',
          name: 'single.pdf',
          folderId: 'f1',
          totalSize: 1024,
          mimeType: 'application/pdf',
          createdAt: DateTime.parse('2026-06-19T12:00:00.000Z'),
          parts: const [FilePart(messageId: 10, part: 0, size: 1024)],
        ),
        FileItem(
          id: 'file2',
          name: 'movie.mkv',
          folderId: null,
          totalSize: 5_000_000_000,
          mimeType: 'video/x-matroska',
          createdAt: DateTime.parse('2026-06-19T13:00:00.000Z'),
          parts: const [
            FilePart(messageId: 20, part: 0, size: 2_000_000_000),
            FilePart(messageId: 21, part: 1, size: 2_000_000_000),
            FilePart(messageId: 22, part: 2, size: 1_000_000_000),
          ],
        ),
      ],
    );

    test('round-trips through encode/decode without loss', () {
      final decoded = FileIndex.decode(sample.encode());

      expect(decoded.version, FileIndex.currentVersion);
      expect(decoded.folders.length, 2);
      expect(decoded.files.length, 2);

      final movie = decoded.files.firstWhere((f) => f.id == 'file2');
      expect(movie.isMultiPart, isTrue);
      expect(movie.parts.length, 3);
      expect(movie.totalSize, 5_000_000_000);
      expect(movie.folderId, isNull);
      expect(movie.parts[2].messageId, 22);

      final pdf = decoded.files.firstWhere((f) => f.id == 'file1');
      expect(pdf.isMultiPart, isFalse);
      expect(pdf.createdAt, DateTime.parse('2026-06-19T12:00:00.000Z'));
    });

    test('empty index encodes and decodes', () {
      final decoded = FileIndex.decode(FileIndex.empty().encode());
      expect(decoded.folders, isEmpty);
      expect(decoded.files, isEmpty);
    });

    test('tolerates missing folders/files keys', () {
      final decoded = FileIndex.decode('{"version":1}');
      expect(decoded.folders, isEmpty);
      expect(decoded.files, isEmpty);
    });
  });

  group('FileIndex mutations', () {
    test('filesIn and foldersIn filter by parent', () {
      const index = FileIndex(
        folders: [Folder(id: 'a', name: 'A', parentId: null)],
        files: [],
      );
      expect(index.foldersIn(null).length, 1);
      expect(index.foldersIn('a'), isEmpty);
    });

    test('removeFolder detaches its files to root', () {
      final index = FileIndex(
        folders: const [Folder(id: 'a', name: 'A', parentId: null)],
        files: [
          FileItem(
            id: 'x',
            name: 'x.txt',
            folderId: 'a',
            totalSize: 1,
            mimeType: 'text/plain',
            createdAt: DateTime.parse('2026-06-19T00:00:00.000Z'),
            parts: const [FilePart(messageId: 1, part: 0, size: 1)],
          ),
        ],
      );

      final after = index.removeFolder('a');
      expect(after.folders, isEmpty);
      expect(after.files.single.folderId, isNull,
          reason: 'orphaned file should move to root');
    });

    test('addFile and removeFile', () {
      final file = FileItem(
        id: 'n',
        name: 'n.bin',
        folderId: null,
        totalSize: 2,
        mimeType: 'application/octet-stream',
        createdAt: DateTime.parse('2026-06-19T00:00:00.000Z'),
        parts: const [FilePart(messageId: 5, part: 0, size: 2)],
      );
      final added = const FileIndex().addFile(file);
      expect(added.files.length, 1);
      expect(added.removeFile('n').files, isEmpty);
    });
  });

  group('FileIndex.merge', () {
    test('later snapshot wins for album fields, member ids are unioned', () {
      final created = DateTime.parse('2026-06-19T00:00:00.000Z');
      final old = FileIndex(
          albums: [Album(id: 'a', name: 'Old name', fileIds: const ['x'], createdAt: created)]);
      final live = FileIndex(
          albums: [Album(id: 'a', name: 'Live name', fileIds: const ['y'], createdAt: created)]);
      final merged = FileIndex.merge([old, live]);
      expect(merged.albums.single.name, 'Live name');
      expect(merged.albums.single.fileIds, ['x', 'y']);
    });
  });

  group('FileIndex.findUpload', () {
    final index = FileIndex(files: [
      FileItem(
        id: 'existing',
        name: 'IMG_0001.jpg',
        folderId: null,
        totalSize: 12345,
        mimeType: 'image/jpeg',
        createdAt: DateTime.parse('2026-06-19T00:00:00.000Z'),
        parts: const [FilePart(messageId: 1, part: 0, size: 12345)],
      ),
    ]);

    test('matches on exact name and size — the reinstall-healing case', () {
      final found = index.findUpload('IMG_0001.jpg', 12345);
      expect(found?.id, 'existing');
    });

    test('same name, different size is not a match', () {
      expect(index.findUpload('IMG_0001.jpg', 99), isNull);
    });

    test('same size, different name is not a match', () {
      expect(index.findUpload('IMG_9999.jpg', 12345), isNull);
    });

    test('no match returns null', () {
      expect(index.findUpload('nope.jpg', 1), isNull);
    });
  });
}
