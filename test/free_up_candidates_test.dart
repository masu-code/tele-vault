import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/profile/screens/free_up_storage_screen.dart';
import 'package:tele_vault/models/capture_date.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

/// D1: "Free up space" deletes device originals, so it may only offer assets
/// whose linked file is in an index read from Telegram, never on the
/// registry's "uploaded" flag alone.

FileItem _item(String id) => FileItem(
      id: id,
      name: '$id.jpg',
      folderId: null,
      totalSize: 10,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026),
      parts: [FilePart(messageId: 1, part: 0, size: 10)],
    );

void main() {
  final links = {'a1': 'f1', 'a2': 'f2', 'a3': 'gone'};
  final index = FileIndex.empty().addFiles([_item('f1'), _item('f2')]);

  test('an index not synced with Telegram offers no candidate', () {
    expect(
      deletableAssetIds(
        uploaded: links.keys,
        fileItemIdFor: (id) => links[id],
        index: index,
        synced: false,
      ),
      isEmpty,
    );
  });

  test('an asset linked to an id missing from the index is excluded', () {
    expect(
      deletableAssetIds(
        uploaded: links.keys,
        fileItemIdFor: (id) => links[id],
        index: index,
        synced: true,
      ),
      ['a1', 'a2'],
    );
  });

  test('an uploaded asset with no link is excluded', () {
    expect(
      deletableAssetIds(
        uploaded: ['a1', 'unlinked'],
        fileItemIdFor: (id) => links[id],
        index: index,
        synced: true,
      ),
      ['a1'],
    );
  });

  group('stamp capture dates before deleting', () {
    // a1 -> f1 undated, a2 -> f2 undated (removed by another writer during
    // the save), a3 -> f3 already dated, a4 -> f4 undated and the device has
    // no believable date for it.
    final shotMs = DateTime(2024, 3, 9, 10).millisecondsSinceEpoch;
    final stampLinks = {'a1': 'f1', 'a2': 'f2', 'a3': 'f3', 'a4': 'f4'};
    final deviceMs = {'a1': shotMs, 'a2': shotMs, 'a3': shotMs, 'a4': null};
    final start = FileIndex.empty().addFiles([
      _item('f1'),
      _item('f2'),
      withTakenAt(_item('f3'), shotMs - 1000),
      _item('f4'),
    ]);

    Future<FreeUpDeletePlan> run(
      Future<FileIndex> Function(FileIndex Function(FileIndex) mutate) save, {
      bool synced = true,
    }) =>
        stampThenSelectForDelete(
          selected: stampLinks.keys,
          fileItemIdFor: (id) => stampLinks[id],
          deviceCaptureMsFor: (id) => deviceMs[id],
          index: start,
          synced: synced,
          applyAndSave: save,
        );

    test('a failed save leads to zero deletions', () async {
      final deleted = <String>[];
      Object? error;
      try {
        final plan = await run((_) async => throw StateError('save failed'));
        deleted.addAll(plan.assetIds);
      } catch (e) {
        error = e;
      }
      expect(error, isA<StateError>());
      expect(deleted, isEmpty);
    });

    test('deletes only dated items present in the returned index', () async {
      var saves = 0;
      late FileIndex written;
      final plan = await run((mutate) async {
        saves++;
        // Another writer removed f2 while this save was rebased.
        written = mutate(start).removeFile('f2');
        return written;
      });
      expect(saves, 1);
      expect(plan.assetIds, ['a1', 'a3']);
      expect(plan.undated, 1);
      final byId = {for (final f in written.files) f.id: f};
      expect(byId['f1']!.extra[takenAtKey], shotMs);
      // A stored date is never overwritten.
      expect(byId['f3']!.extra[takenAtKey], shotMs - 1000);
      expect(hasStoredTakenAt(byId['f4']!), isFalse);
    });

    test('an asset with no believable device date is excluded', () async {
      final plan = await run((mutate) async => mutate(start));
      expect(plan.assetIds, isNot(contains('a4')));
      expect(plan.assetIds, ['a1', 'a2', 'a3']);
      expect(plan.undated, 1);
    });

    test('not synced: nothing is saved or deleted', () async {
      var saves = 0;
      final plan = await run((mutate) async {
        saves++;
        return mutate(start);
      }, synced: false);
      expect(saves, 0);
      expect(plan.assetIds, isEmpty);
    });
  });
}
