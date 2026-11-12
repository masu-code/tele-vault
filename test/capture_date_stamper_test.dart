import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/services/capture_date_stamper.dart';
import 'package:tele_vault/features/gallery/services/gallery_feed_service.dart';
import 'package:tele_vault/models/capture_date.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// A plausible device date base (seconds).
const _base = 1700000000;

AssetEntity _asset(String id, int? createSec, {String? title}) => AssetEntity(
      id: id,
      typeInt: 1,
      width: 10,
      height: 10,
      title: title,
      createDateSecond: createSec == null ? null : _base + createSec,
      modifiedDateSecond: 0,
    );

// Uploaded "now": without a stored date the item would sort on top.
FileItem _file(String id) => FileItem(
      id: id,
      name: '$id.mp4',
      folderId: null,
      totalSize: 100,
      mimeType: 'video/mp4',
      createdAt: DateTime(2026, 11, 1),
      parts: const [FilePart(messageId: 1, part: 0, size: 100)],
    );

void main() {
  // Five pairs linked through the registry, one pair whose device date is
  // unusable, and one device-only asset.
  final links = {for (var i = 0; i < 6; i++) 'a$i': 'f$i'};
  final assets = [
    for (var i = 0; i < 5; i++) _asset('a$i', i * 86400, title: 'a$i.mp4'),
    _asset('a5', null, title: 'a5.mp4'),
    _asset('lonely', 3 * 86400 + 5, title: 'lonely.mp4'),
  ];
  final start = FileIndex(files: [
    for (var i = 0; i < 6; i++) _file('f$i'),
    _file('cloud'),
  ]);

  List<GalleryEntry> feed(FileIndex index) =>
      mergeFeed(assets: assets, index: index, fileItemIdFor: (id) => links[id]);
  List<String> order(List<GalleryEntry> entries) =>
      [for (final e in entries) e.key];

  test('pendingCaptureStamps: only dated pairs without taken_at, capped', () {
    final pending = pendingCaptureStamps(feed(start));
    expect(pending.keys.toSet(), {'f0', 'f1', 'f2', 'f3', 'f4'});
    expect(pending['f2'], (_base + 2 * 86400) * 1000);
    expect(pendingCaptureStamps(feed(start), limit: 2), hasLength(2));
  });

  test('pendingCaptureStamps: only registry-linked pairs when a link lookup is given', () {
    // f0..f4 are linked to a0..a4; pretend only a1 and a3 are registry links.
    String? linkOnly(String assetId) =>
        {'a1': 'f1', 'a3': 'f3'}[assetId];
    final pending = pendingCaptureStamps(feed(start), linkedFileIdFor: linkOnly);
    expect(pending.keys.toSet(), {'f1', 'f3'});
    // A link that points at a different file than the pair's never stamps.
    final crossed = pendingCaptureStamps(
      feed(start),
      linkedFileIdFor: (id) => id == 'a2' ? 'f4' : null,
    );
    expect(crossed, isEmpty);
  });

  group('CaptureDateStamper', () {
    late FileIndex index;
    late int saves;
    late List<int> batchSizes;
    late CaptureDateStamper stamper;
    var synced = true;
    var idle = true;

    setUp(() {
      index = start;
      saves = 0;
      batchSizes = [];
      synced = true;
      idle = true;
      stamper = CaptureDateStamper(
        isSynced: () => synced,
        isIdle: () => idle,
        batchSize: 2,
        applyAndSave: (mutate) async {
          final before = index.files.where(hasStoredTakenAt).length;
          index = mutate(index);
          saves++;
          batchSizes.add(index.files.where(hasStoredTakenAt).length - before);
          return index;
        },
      );
      addTearDown(stamper.dispose);
    });

    test('batches of batchSize, idempotent, no change in order', () async {
      final initialOrder = order(feed(start));
      for (var round = 0; round < 5; round++) {
        final entries = feed(index);
        expect(order(entries), initialOrder);
        stamper.onFeedBuilt(entries);
        await stamper.flush();
      }
      expect(batchSizes, [2, 2, 1]);
      expect(saves, 3);
      expect(order(feed(index)), initialOrder);

      // Every pair with a believable device date is stamped with exactly the
      // date its entry shows; the undatable pair and the cloud-only item are
      // left alone.
      final shown = {for (final e in feed(start)) e.key: e.effectiveDateMs};
      final byId = {for (final f in index.files) f.id: f};
      for (var i = 0; i < 5; i++) {
        expect(byId['f$i']!.extra[takenAtKey], shown['a$i']);
      }
      expect(hasStoredTakenAt(byId['f5']!), isFalse);
      expect(hasStoredTakenAt(byId['cloud']!), isFalse);

      // Once the device copies are gone the cloud items keep their place.
      final cloudOnly = mergeFeed(
        assets: const [],
        index: index,
        fileItemIdFor: (_) => null,
      );
      for (final e in cloudOnly) {
        final i = e.fileItem!.id.substring(1);
        if (shown.containsKey('a$i') && i != '5') {
          expect(e.effectiveDateMs, shown['a$i']);
        }
      }
    });

    test('nothing pending: no save', () async {
      final done = stampTakenAt(start, pendingCaptureStamps(feed(start)));
      index = done;
      stamper.onFeedBuilt(feed(done));
      await stamper.flush();
      expect(saves, 0);
    });

    test('not synced or not idle: no save', () async {
      synced = false;
      stamper.onFeedBuilt(feed(index));
      await stamper.flush();
      expect(saves, 0);

      synced = true;
      idle = false;
      stamper.onFeedBuilt(feed(index));
      await stamper.flush();
      expect(saves, 0);

      idle = true;
      await stamper.flush();
      expect(saves, 1);
    });

    test('a failed save is not retried right away', () async {
      final failing = CaptureDateStamper(
        isSynced: () => true,
        isIdle: () => true,
        applyAndSave: (_) async {
          saves++;
          throw StateError('offline');
        },
      );
      addTearDown(failing.dispose);
      failing.onFeedBuilt(feed(index));
      await failing.flush();
      failing.onFeedBuilt(feed(index));
      await failing.flush();
      expect(saves, 1);
    });
  });

  test('stampTakenAt returns the same index when nothing changes', () {
    expect(identical(stampTakenAt(start, const {}), start), isTrue);
    final once = stampTakenAt(start, {'f0': 1700000000000});
    expect(identical(stampTakenAt(once, {'f0': 1700000000001}), once), isTrue);
  });

  test('FileItem.withExtra keeps other keys and round-trips in JSON', () {
    final f = FileItem.fromJson({
      ..._file('x').toJson(),
      'future_key': 'kept',
    });
    final stamped = withTakenAt(f, 1700000000000);
    expect(stamped.extra, {'future_key': 'kept', takenAtKey: 1700000000000});
    expect(stamped.copyWith(name: 'y.mp4').extra, stamped.extra);
    final back = FileItem.fromJson(stamped.toJson());
    expect(back.extra[takenAtKey], 1700000000000);
    expect(back.extra['future_key'], 'kept');
    expect(f.extra.containsKey(takenAtKey), isFalse);
  });
}
