import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/core/backup/backup_service.dart';
import 'package:tele_vault/core/diag/tv_stats.dart';
import 'package:tele_vault/features/albums/screens/albums_screen.dart';
import 'package:tele_vault/features/backup/providers/backup_provider.dart';
import 'package:tele_vault/features/explorer/providers/index_provider.dart';
import 'package:tele_vault/features/transfer/providers/transfer_queue_provider.dart';
import 'package:tele_vault/models/album.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

FileItem _file(String id) => FileItem(
  id: id,
  name: '$id.jpg',
  folderId: null,
  totalSize: 100,
  mimeType: 'image/jpeg',
  createdAt: DateTime(2026, 1, 1),
  parts: const [FilePart(messageId: 1, part: 0, size: 100)],
);

Album _album(String name, List<String> ids) => Album(
  id: 'album1',
  name: name,
  fileIds: ids,
  createdAt: DateTime(2026, 1, 1),
);

class _FakeIndex extends IndexNotifier {
  _FakeIndex(super.ref, FileIndex initial) {
    state = IndexState(index: initial);
  }

  void emit(FileIndex index) => state = state.copyWith(index: index);
}

class _FakeBackup extends BackupNotifier {
  _FakeBackup(super.ref);

  void emit(BackupState s) => state = s;

  @override
  Future<void> loadDeviceAlbums() async {}
}

class _FakeTransfer extends TransferQueueNotifier {
  _FakeTransfer(super.ref);

  void emit(TransferState s) => state = s;
}

void main() {
  testWidgets(
    'AlbumsScreen does not rebuild on transfer progress, unrelated index '
    'changes or backup progress; it does on a real album change',
    (tester) async {
      late _FakeIndex index;
      late _FakeBackup backup;
      late _FakeTransfer transfer;
      final fileA = _file('a'); // not in any album: no cover, no thumb request
      final container = ProviderContainer(
        overrides: [
          indexProvider.overrideWith((ref) {
            return index = _FakeIndex(
              ref,
              FileIndex(files: [fileA], albums: [_album('Trip', const [])]),
            );
          }),
          backupProvider.overrideWith((ref) => backup = _FakeBackup(ref)),
          transferQueueProvider.overrideWith(
            (ref) => transfer = _FakeTransfer(ref),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AlbumsScreen()),
        ),
      );
      await tester.pump();
      expect(find.text('Trip'), findsOneWidget);

      TvStats.screenBuilds.clear();
      int builds() => TvStats.screenBuilds['albums'] ?? 0;

      // A 20-file upload: per-file progress ticks from the transfer queue.
      for (var i = 0; i < 20; i++) {
        transfer.emit(
          TransferState(
            active: true,
            total: 20,
            done: i,
            currentProgress: 0.5,
          ),
        );
        await tester.pump();
      }
      // Each finished upload lands in the index (unrelated to any album).
      var files = [fileA];
      for (var i = 0; i < 20; i++) {
        files = [...files, _file('new$i')];
        index.emit(
          FileIndex(files: files, albums: [_album('Trip', const [])]),
        );
        await tester.pump();
      }
      // Backup progress for some album.
      backup.emit(
        const BackupState(
          progress: {'dev1': BackupProgress(total: 10, done: 3)},
        ),
      );
      await tester.pump();
      expect(builds(), 0, reason: 'albums tab rebuilt by unrelated changes');

      // Control: a rename really changes what the screen shows.
      index.emit(FileIndex(files: files, albums: [_album('Trip 2', const [])]));
      await tester.pump();
      expect(builds(), 1);
      expect(find.text('Trip 2'), findsOneWidget);
    },
  );
}
