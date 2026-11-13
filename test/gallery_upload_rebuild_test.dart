import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tele_vault/core/diag/tv_stats.dart';
import 'package:tele_vault/features/explorer/providers/index_provider.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/providers/gallery_feed_provider.dart';
import 'package:tele_vault/features/gallery/providers/thumb_prefetch_provider.dart';
import 'package:tele_vault/features/gallery/screens/gallery_screen.dart';
import 'package:tele_vault/features/gallery/services/gallery_feed_service.dart';
import 'package:tele_vault/models/capture_date.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// A 6000-photo device library (half of it already uploaded) on the real
// GalleryScreen, then 20 uploads finishing one after another, each feeding
// the screen the way GalleryFeedService.buildEntries does on Android: a fresh
// mergeFeed of the device library against the new index, adopted against the
// previous feed.

const _base = 1780000000; // seconds; newest photo, Jun 2026
const _step = 10500; // ~2 years over 6000 photos

AssetEntity _asset(int i) => AssetEntity(
  id: 'd$i',
  typeInt: 1,
  width: 10,
  height: 10,
  title: 'IMG_$i.jpg',
  createDateSecond: _base - i * _step,
  modifiedDateSecond: _base - i * _step,
);

FileItem _cloud(String id, int i) => FileItem(
  id: id,
  name: 'IMG_$i.jpg',
  folderId: null,
  totalSize: 100,
  mimeType: 'image/jpeg',
  createdAt: DateTime.utc(2026, 6, 20),
  parts: const [FilePart(messageId: 1, part: 0, size: 100)],
  extra: takenAtExtra((_base - i * _step) * 1000),
);

class _FakeIndex extends IndexNotifier {
  _FakeIndex(super.ref, FileIndex initial) {
    state = IndexState(index: initial);
  }

  void emit(FileIndex index) => state = state.copyWith(index: index);
}

void main() {
  group('adoptFeed', () {
    List<GalleryEntry> cloudFeed(FileIndex index) => sortNewestFirst([
      for (final f in index.mediaFiles) GalleryEntry(fileItem: f),
    ]);

    final files = [for (var i = 0; i < 50; i++) _cloud('c$i', i)];

    test('value-equal items keep the previous list and entries', () {
      final index = FileIndex(files: files);
      final first = adoptFeed(null, cloudFeed(index));
      final reread = FileIndex.decode(index.encode());
      expect(identical(reread.files.first, index.files.first), isFalse);
      expect(identical(adoptFeed(first, cloudFeed(reread)), first), isTrue);
    });

    test('one changed item: only that entry is new', () {
      final first = adoptFeed(null, cloudFeed(FileIndex(files: files)));
      final renamed = [
        for (final f in files) f.id == 'c7' ? f.copyWith(name: 'x.jpg') : f,
      ];
      final next = adoptFeed(first, cloudFeed(FileIndex(files: renamed)));
      expect(identical(next, first), isFalse);
      for (var i = 0; i < next.length; i++) {
        expect(identical(next[i], first[i]), next[i].key != 'c7');
      }
      expect(next.firstWhere((e) => e.key == 'c7').fileItem!.name, 'x.jpg');
    });

    test('new, archived and re-dated items show up', () {
      final index = FileIndex(files: files);
      final first = adoptFeed(null, cloudFeed(index));

      final added = adoptFeed(
        first,
        cloudFeed(index.addFile(_cloud('new', -10))),
      );
      expect(added.first.key, 'new');
      expect(added.length, first.length + 1);

      final archived = adoptFeed(first, cloudFeed(index.archiveFiles(['c3'])));
      expect(archived.any((e) => e.key == 'c3'), isFalse);

      // A new capture date moves the item to another month.
      final redated = [
        for (final f in files)
          f.id == 'c0'
              ? f.copyWith(
                  extra: takenAtExtra(DateTime(2020).millisecondsSinceEpoch),
                )
              : f,
      ];
      final moved = adoptFeed(first, cloudFeed(FileIndex(files: redated)));
      expect(moved.last.key, 'c0');
      expect(moved.last.effectiveDate.year, 2020);
    });

    test('a stamped taken_at reaches the entry (capture-date stamper)', () {
      final asset = _asset(5);
      final bare = FileItem(
        id: 'c5',
        name: 'IMG_5.jpg',
        folderId: null,
        totalSize: 100,
        mimeType: 'image/jpeg',
        createdAt: DateTime.utc(2026, 6, 20),
        parts: const [FilePart(messageId: 1, part: 0, size: 100)],
      );
      final first = adoptFeed(null, [
        GalleryEntry(asset: asset, fileItem: bare),
      ]);
      final stamped = stampTakenAt(FileIndex(files: [bare]), {
        'c5': (_base - 5 * _step) * 1000,
      });
      final next = adoptFeed(first, [
        GalleryEntry(asset: asset, fileItem: stamped.files.single),
      ]);
      expect(identical(next, first), isFalse);
      expect(next.single.fileItem!.extra, stamped.files.single.extra);
    });

    test('groups of untouched months keep their instance', () {
      final first = adoptFeed(null, cloudFeed(FileIndex(files: files)));
      final groupsA = groupEntriesByMonth(first);
      final renamed = [
        for (final f in files) f.id == 'c7' ? f.copyWith(name: 'x.jpg') : f,
      ];
      final next = adoptFeed(first, cloudFeed(FileIndex(files: renamed)));
      final groupsB = groupEntriesByMonth(next);
      expect(groupsB.length, groupsA.length);
      for (var i = 0; i < groupsB.length; i++) {
        final touched = groupsB[i].entries.any((e) => e.key == 'c7');
        expect(identical(groupsB[i], groupsA[i]), !touched);
      }
    });
  });

  testWidgets('index writes during a queue run coalesce into few feed builds', (
    tester,
  ) async {
    late _FakeIndex fake;
    final container = ProviderContainer(
      overrides: [
        indexProvider.overrideWith(
          (ref) => fake = _FakeIndex(ref, FileIndex(files: [_cloud('c0', 0)])),
        ),
      ],
    );
    addTearDown(container.dispose);

    var builds = 0;
    List<GalleryEntry>? last;
    container.listen(galleryFeedProvider, (_, next) {
      final v = next.valueOrNull;
      if (v != null && !identical(v, last)) {
        builds++;
        last = v;
      }
    }, fireImmediately: true);
    await tester.pump(const Duration(seconds: 1));
    expect(builds, 1);

    // One index write every 600 ms (more than the settle delay apart) for
    // 12 s, like a queue flushing small batches of fast uploads.
    var files = [_cloud('c0', 0)];
    builds = 0;
    for (var i = 1; i <= 20; i++) {
      files = [...files, _cloud('c$i', i)];
      fake.emit(FileIndex(files: files));
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pump(const Duration(seconds: 3));
    // ignore: avoid_print
    print('TVDIAG feed builds for 20 writes over 12 s: $builds');
    expect(builds, lessThanOrEqualTo(9), reason: 'at most one per 1.5 s');
    expect(last!.length, 21, reason: 'the final state is never stale');
  });

  testWidgets('20 sequential upload completions on a 6000-item feed', (
    tester,
  ) async {
    const n = 6000;
    final assets = [for (var i = 0; i < n; i++) _asset(i)];
    final links = <String, String>{};
    final files = <FileItem>[];
    for (var i = 1; i < n; i += 2) {
      files.add(_cloud('c$i', i));
      links['d$i'] = 'c$i';
    }
    var index = FileIndex(files: files);

    List<GalleryEntry>? previous;
    List<GalleryEntry> build() {
      final next = mergeFeed(
        assets: assets,
        index: index,
        fileItemIdFor: (id) => links[id],
      );
      return previous = adoptFeed(previous, next);
    }

    final feed = StateProvider<List<GalleryEntry>>((ref) => build());
    final container = ProviderContainer(
      overrides: [
        thumbPrefetchBindingProvider.overrideWith((ref) {}),
        galleryFeedProvider.overrideWith((ref) async => ref.watch(feed)),
      ],
    );
    addTearDown(container.dispose);

    var flatChanges = 0;
    var groupListChanges = 0;
    var groupInstancesChanged = 0;
    List<GalleryEntry>? lastFlat;
    List<GalleryMonthGroup>? lastGroups;
    container.listen(galleryMonthGroupsProvider, (_, next) {
      final groups = next.valueOrNull;
      if (groups == null || identical(groups, lastGroups)) return;
      if (lastGroups != null) {
        groupListChanges++;
        final old = {for (final g in lastGroups!) g.month: g};
        for (final g in groups) {
          if (!identical(old[g.month], g)) groupInstancesChanged++;
        }
      }
      lastGroups = groups;
    }, fireImmediately: true);
    container.listen(galleryFeedProvider, (_, next) {
      final flat = next.valueOrNull;
      if (flat == null || identical(flat, lastFlat)) return;
      if (lastFlat != null) flatChanges++;
      lastFlat = flat;
    }, fireImmediately: true);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MediaQuery(
          data: MediaQueryData(size: Size(400, 800)),
          child: MaterialApp(home: GalleryScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Scrolled a little, so "scroll position untouched" means something.
    final scrollable = find.byType(Scrollable).first;
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(scrollable).position;
    final offsetBefore = position.pixels;
    final badgesBefore = find
        .byIcon(Icons.cloud_done_outlined)
        .evaluate()
        .length;

    TvStats.reset();
    // The 20 newest device-only photos (on or near the screen).
    for (var k = 0; k < 20; k++) {
      final i = 2 * k;
      final item = _cloud('u$i', i);
      index = index.addFile(item);
      links['d$i'] = item.id;
      container.read(feed.notifier).state = build();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    final badgesAfter = find
        .byIcon(Icons.cloud_done_outlined)
        .evaluate()
        .length;
    final stats = {
      'flatChanges': flatChanges,
      'groupListChanges': groupListChanges,
      'groupInstancesChanged': groupInstancesChanged,
      'sliverRebuilds': TvStats.screenBuilds['gallery-slivers'] ?? 0,
      'monthRebuilds': TvStats.screenBuilds['gallery-month'] ?? 0,
      'tileInits': TvStats.tileInits,
      'tileBuilds': TvStats.tileBuilds,
      'badgesBefore': badgesBefore,
      'badgesAfter': badgesAfter,
      'offsetBefore': offsetBefore,
      'offsetAfter': position.pixels,
    };
    // ignore: avoid_print
    print('TVDIAG upload-rebuild: $stats');

    // Each upload changes one entry: one month section, one tile.
    expect(groupInstancesChanged, lessThanOrEqualTo(20));
    expect(TvStats.screenBuilds['gallery-month'] ?? 0, lessThanOrEqualTo(20));
    expect(TvStats.tileInits, 0, reason: 'unchanged tiles were re-created');
    expect(TvStats.tileBuilds, lessThanOrEqualTo(20));
    expect(position.pixels, offsetBefore);
    expect(badgesAfter, greaterThan(badgesBefore));
    expect(
      find.byKey(const ValueKey('d0'), skipOffstage: false),
      findsOneWidget,
    );

    // The index re-read from Telegram (or rebased onto another writer's
    // copy): every FileItem is a new instance, nothing visible changed.
    final flatBefore = lastFlat;
    final groupsBefore = lastGroups;
    TvStats.reset();
    index = FileIndex.decode(index.encode());
    container.read(feed.notifier).state = build();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(identical(lastFlat, flatBefore), isTrue);
    expect(identical(lastGroups, groupsBefore), isTrue);
    expect(TvStats.tileBuilds, 0);

    // Real changes still show up: an archived photo leaves the grid...
    index = index.archiveFiles(['u0']);
    container.read(feed.notifier).state = build();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('d0'), skipOffstage: false), findsNothing);
    expect(identical(lastFlat, flatBefore), isFalse);

    // ...and a new one lands at the top.
    assets.insert(
      0,
      AssetEntity(
        id: 'dnew',
        typeInt: 1,
        width: 10,
        height: 10,
        title: 'IMG_new.jpg',
        createDateSecond: _base + 60,
        modifiedDateSecond: _base + 60,
      ),
    );
    container.read(feed.notifier).state = build();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(lastFlat!.first.key, 'dnew');
    expect(
      find.byKey(const ValueKey('dnew'), skipOffstage: false),
      findsOneWidget,
    );
    expect(position.pixels, offsetBefore);
  });
}
