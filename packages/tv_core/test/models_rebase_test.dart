import 'package:test/test.dart';
import 'package:tv_core/models.dart';

FileItem file(String id, {String? name, int size = 100, bool archived = false, String? preview, String? folderId}) =>
    FileItem(
      id: id,
      name: name ?? 'n_$id',
      folderId: folderId,
      totalSize: size,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026, 1, 1),
      parts: [FilePart(messageId: id.hashCode & 0xffff, part: 0, size: size)],
      archived: archived,
      preview: preview,
    );

Album album(String id, List<String> ids, {String name = 'A'}) =>
    Album(id: id, name: name, fileIds: ids, createdAt: DateTime.utc(2026));

List<String> ids(FileIndex i) => i.files.map((f) => f.id).toList();

void main() {
  group('FileIndex.rebase', () {
    test('disjoint adds on both sides keep both', () {
      final base = FileIndex(files: [file('a')]);
      final local = base.addFile(file('l1'));
      final remote = base.addFile(file('r1')).addFile(file('r2'));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(ids(res.index), ['a', 'r1', 'r2', 'l1']);
      expect(res.droppedDuplicates, isEmpty);
    });

    test('local delete vs remote edit: deletion applies', () {
      final base = FileIndex(files: [file('a'), file('b')]);
      final local = base.removeFile('a');
      final remote = base.renameFile('a', 'renamed');
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(ids(res.index), ['b']);
    });

    test('remote delete of something local did not touch stays deleted', () {
      final base = FileIndex(files: [file('a'), file('b')]);
      final res = FileIndex.rebase(
          base: base, local: base, remote: base.removeFile('a'));
      expect(ids(res.index), ['b']);
    });

    test('same add on both sides keeps a single copy (remote wins)', () {
      final base = FileIndex();
      final local = base.addFile(file('x'));
      final remote = base.addFile(file('x'));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(ids(res.index), ['x']);
      expect(res.droppedDuplicates, isEmpty);
    });

    test('duplicate by name+size under another id is dropped and reported', () {
      final base = FileIndex();
      final local = base.addFiles([
        file('local-dup', name: 'IMG_1.jpg', size: 500),
        file('local-ok', name: 'IMG_2.jpg', size: 500),
      ]);
      final remote = base.addFile(file('remote-dup', name: 'IMG_1.jpg', size: 500));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(ids(res.index), ['remote-dup', 'local-ok']);
      expect(res.droppedDuplicates, ['local-dup']);
    });

    test('same name, different size is not a duplicate', () {
      final base = FileIndex();
      final res = FileIndex.rebase(
        base: base,
        local: base.addFile(file('l', name: 'a.jpg', size: 1)),
        remote: base.addFile(file('r', name: 'a.jpg', size: 2)),
      );
      expect(ids(res.index), ['r', 'l']);
      expect(res.droppedDuplicates, isEmpty);
    });

    test('archived change on local side only is taken', () {
      final base = FileIndex(files: [file('a'), file('b')]);
      final local = base.archiveFiles(['a']);
      final remote = base.addFile(file('c'));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.files.firstWhere((f) => f.id == 'a').archived, isTrue);
      expect(ids(res.index), ['a', 'b', 'c']);
    });

    test('archived change on remote side only is kept', () {
      final base = FileIndex(files: [file('a')]);
      final remote = base.archiveFiles(['a']);
      final local = base.addFile(file('n'));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.files.firstWhere((f) => f.id == 'a').archived, isTrue);
      expect(ids(res.index), ['a', 'n']);
    });

    test('album membership merges as sets, remote order first', () {
      final base = FileIndex(
        files: [file('a'), file('b'), file('c')],
        albums: [album('al', ['a', 'b'])],
      );
      final local = base.removeFromAlbum('al', ['a']).addToAlbum('al', ['l']);
      final remote = base.addToAlbum('al', ['r']);
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.albums.single.fileIds, ['b', 'r', 'l']);
    });

    test('local album rename keeps remote members', () {
      final base = FileIndex(albums: [album('al', ['a'])]);
      final local = base.renameAlbum('al', 'New');
      final remote = base.addToAlbum('al', ['r']);
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.albums.single.name, 'New');
      expect(res.index.albums.single.fileIds, ['a', 'r']);
    });

    test('local album addition and local album deletion', () {
      final base = FileIndex(albums: [album('old', [])]);
      final local = base.removeAlbum('old').addAlbum(album('new', ['x']));
      final res = FileIndex.rebase(base: base, local: local, remote: base);
      expect(res.index.albums.map((a) => a.id), ['new']);
    });

    test('dropped duplicate in a new local album is remapped to remote id', () {
      final base = FileIndex();
      final local = base
          .addFile(file('ldup', name: 'p.jpg', size: 9))
          .addAlbum(album('al', ['ldup']));
      final remote = base.addFile(file('rdup', name: 'p.jpg', size: 9));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.albums.single.fileIds, ['rdup']);
    });

    test('locally deleted file is removed from remote-side album membership', () {
      final base = FileIndex(
          files: [file('a')], albums: [album('al', ['a'])]);
      final local = base.removeFile('a');
      final remote = base.addFile(file('b')).addToAlbum('al', ['b']);
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(ids(res.index), ['b']);
      expect(res.index.albums.single.fileIds, ['b']);
    });

    test('folders: local rename + remote add; local delete detaches', () {
      final base = FileIndex(
        folders: const [Folder(id: 'f', name: 'F', parentId: null)],
      );
      final local = base.renameFolder('f', 'F2');
      final remote = base.addFolder(const Folder(id: 'g', name: 'G', parentId: null));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.folders.map((f) => '${f.id}:${f.name}'), ['f:F2', 'g:G']);

      final delLocal = base.removeFolder('f');
      final remoteChild = base.addFile(file('c', folderId: 'f'));
      final res2 = FileIndex.rebase(base: base, local: delLocal, remote: remoteChild);
      expect(res2.index.folders, isEmpty);
      expect(res2.index.files.single.folderId, isNull);
    });

    test('previews: non-null wins, local over remote', () {
      final base = FileIndex(files: [file('a'), file('b'), file('c')]);
      final local = base.withPreviews({'a': 'th1:LOCAL', 'b': 'th1:LB'});
      final remote = base.withPreviews({'a': 'th1:REMOTE', 'c': 'th1:RC'});
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      String? p(String id) => res.index.files.firstWhere((f) => f.id == id).preview;
      expect(p('a'), 'th1:LOCAL');
      expect(p('b'), 'th1:LB');
      expect(p('c'), 'th1:RC');
    });

    test('thumb packs union by messageId', () {
      ThumbPackRef pk(int m) => ThumbPackRef(
          id: 'p$m', messageId: m, count: 1, size: 1, createdAt: DateTime.utc(2026));
      final base = FileIndex(thumbPacks: [pk(1)]);
      final local = base.addThumbPack(pk(2));
      final remote = base.addThumbPack(pk(3));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.thumbPacks.map((p) => p.messageId), [1, 3, 2]);
    });

    test('unknown index keys: remote kept, local changes applied', () {
      final base = FileIndex.fromJson({'version': 1, 'k1': 1, 'k2': 1});
      final local = FileIndex.fromJson({'version': 1, 'k1': 1, 'k2': 2});
      final remote = FileIndex.fromJson({'version': 1, 'k1': 5, 'k2': 1, 'k3': 3});
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.extra, {'k1': 5, 'k2': 2, 'k3': 3});
    });

    test('nothing changed anywhere returns remote content', () {
      final base = FileIndex(
          files: [file('a')], albums: [album('al', ['a'])]);
      final res = FileIndex.rebase(base: base, local: base, remote: base);
      expect(res.index.encode(), base.encode());
    });

    test('local delete + re-upload of the same file under a new id keeps the new one', () {
      final base = FileIndex(files: [file('x', name: 'IMG_9.jpg', size: 700)]);
      final local = base
          .removeFile('x')
          .addFile(file('y', name: 'IMG_9.jpg', size: 700));
      final remote = base.addFile(file('r1'));
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(ids(res.index), ['r1', 'y']);
      expect(res.droppedDuplicates, isEmpty);
    });

    test('local preview-only change does not override a remote archive/rename/move', () {
      final base = FileIndex(files: [file('a'), file('b'), file('c')]);
      final local = base.withPreviews({'a': 'th1:AAAA', 'b': 'th1:BBBB', 'c': 'th1:CCCC'});
      final remote = base
          .archiveFiles(['a'])
          .renameFile('b', 'renamed')
          .moveFiles(['c'], 'folder1');
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      final byId = {for (final f in res.index.files) f.id: f};
      expect(byId['a']!.archived, isTrue);
      expect(byId['a']!.preview, 'th1:AAAA');
      expect(byId['b']!.name, 'renamed');
      expect(byId['b']!.preview, 'th1:BBBB');
      expect(byId['c']!.folderId, 'folder1');
      expect(byId['c']!.preview, 'th1:CCCC');
    });

    test('local album member-only change does not override a remote rename', () {
      final base = FileIndex(
          files: [file('a'), file('b')], albums: [album('al', ['a'], name: 'Old')]);
      final local = base.addToAlbum('al', ['b']);
      final remote = base.renameAlbum('al', 'New');
      final res = FileIndex.rebase(base: base, local: local, remote: remote);
      expect(res.index.albums.single.name, 'New');
      expect(res.index.albums.single.fileIds, ['a', 'b']);
    });
  });
}
