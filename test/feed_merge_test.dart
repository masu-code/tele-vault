import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/services/gallery_feed_service.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// Device dates below 2000 are discarded as implausible (see
// plausibleCaptureMs), so the synthetic seconds sit on top of a real base.
const _base = 1700000000;

AssetEntity _asset(String id, int createSec, {String? title, int? modSec}) =>
    AssetEntity(
      id: id,
      typeInt: 1,
      width: 10,
      height: 10,
      title: title,
      createDateSecond: _base + createSec,
      modifiedDateSecond: modSec ?? createSec,
    );

FileItem _file(
  String id,
  DateTime createdAt, {
  String? name,
  bool archived = false,
  String mime = 'image/jpeg',
}) =>
    FileItem(
      id: id,
      name: name ?? '$id.jpg',
      folderId: null,
      totalSize: 100,
      mimeType: mime,
      createdAt: createdAt,
      parts: const [FilePart(messageId: 1, part: 0, size: 100)],
      archived: archived,
    );

/// Verbatim copy of the pre-T7.3 `GalleryFeedService._merge` (the registry
/// lookup replaced by a function), as the reference the new code must match.
List<GalleryEntry> _oldMerge(
  List<AssetEntity> assets,
  FileIndex index,
  String? Function(String) fileItemIdFor,
) {
  final cloudById = {for (final f in index.files) f.id: f};
  final consumed = <String>{};
  final entries = <GalleryEntry>[];

  final cloudByName = <String, List<FileItem>>{};
  for (final f in index.files) {
    (cloudByName[f.name] ??= []).add(f);
  }
  final deviceNameCount = <String, int>{};
  for (final a in assets) {
    final name = a.title;
    if (name != null) deviceNameCount[name] = (deviceNameCount[name] ?? 0) + 1;
  }

  for (final asset in assets) {
    final fileItemId = fileItemIdFor(asset.id);
    var matched = fileItemId != null ? cloudById[fileItemId] : null;
    if (matched == null) {
      final name = asset.title;
      final candidates = name == null ? null : cloudByName[name];
      if (candidates != null &&
          candidates.length == 1 &&
          deviceNameCount[name] == 1 &&
          !consumed.contains(candidates.first.id)) {
        matched = candidates.first;
      }
    }
    if (matched != null) consumed.add(matched.id);
    if (matched?.archived == true) continue;
    entries.add(GalleryEntry(asset: asset, fileItem: matched));
  }
  for (final f in index.mediaFiles) {
    if (!consumed.contains(f.id)) entries.add(GalleryEntry(fileItem: f));
  }

  entries.sort((a, b) => b.effectiveDate.compareTo(a.effectiveDate));
  return entries;
}

String _sig(GalleryEntry e) => '${e.asset?.id}|${e.fileItem?.id}';

void main() {
  group('mergeFeed vs the old _merge', () {
    for (var seed = 0; seed < 40; seed++) {
      test('random library, seed $seed', () {
        final rnd = Random(seed);
        final nDevice = rnd.nextInt(60);
        final nCloud = rnd.nextInt(60);

        // Distinct dates on both sides so the order is fully determined
        // (the old sort is not stable; ties are checked separately).
        final secs = List<int>.generate(nDevice + nCloud, (i) => 1000 + i)
          ..shuffle(rnd);
        // A small name pool so duplicates and unique matches both occur.
        String? pickName() {
          if (rnd.nextInt(10) == 0) return null;
          return 'IMG_${rnd.nextInt(max(1, (nDevice + nCloud) ~/ 2))}.jpg';
        }

        final assets = <AssetEntity>[
          for (var i = 0; i < nDevice; i++)
            _asset('d$i', secs[i], title: pickName()),
        ];
        final files = <FileItem>[
          for (var i = 0; i < nCloud; i++)
            _file(
              'c$i',
              DateTime.fromMillisecondsSinceEpoch(
                  (_base + secs[nDevice + i]) * 1000 + 500),
              name: pickName() ?? 'c$i.jpg',
              archived: rnd.nextInt(6) == 0,
              mime: ['image/jpeg', 'video/mp4', 'application/pdf'][rnd.nextInt(3)],
            ),
        ];
        final links = <String, String>{
          for (var i = 0; i < nDevice; i++)
            if (nCloud > 0 && rnd.nextInt(4) == 0) 'd$i': 'c${rnd.nextInt(nCloud)}',
        };
        // a link to an id missing from the index is possible after deletions
        if (nDevice > 0) links['d0'] = 'gone';
        final index = FileIndex(files: files);

        final expected = _oldMerge(assets, index, (id) => links[id]);
        final actual = mergeFeed(
          assets: assets,
          index: index,
          fileItemIdFor: (id) => links[id],
        );

        expect(actual.map(_sig).toList(), expected.map(_sig).toList());
      });
    }

    test('equal dates keep input order (device first, then cloud)', () {
      final assets = [_asset('d1', 100), _asset('d2', 100)];
      final index = FileIndex(files: [
        _file('c1', DateTime.fromMillisecondsSinceEpoch((_base + 100) * 1000)),
        _file('c2', DateTime.fromMillisecondsSinceEpoch((_base + 100) * 1000)),
      ]);
      final out =
          mergeFeed(assets: assets, index: index, fileItemIdFor: (_) => null);
      expect(out.map(_sig).toList(),
          ['d1|null', 'd2|null', 'null|c1', 'null|c2']);
    });

    test('registry link, unique-name fallback and archived skip', () {
      final assets = [
        _asset('linked', 500, title: 'x.jpg'),
        _asset('byname', 400, title: 'IMG_1.jpg'),
        _asset('ambiguous', 300, title: 'dup.jpg'),
        _asset('ambiguous2', 200, title: 'dup.jpg'),
        _asset('arch', 100, title: 'arch.jpg'),
      ];
      final index = FileIndex(files: [
        _file('cl', DateTime.fromMillisecondsSinceEpoch(1), name: 'other.jpg'),
        _file('cn', DateTime.fromMillisecondsSinceEpoch(2), name: 'IMG_1.jpg'),
        _file('cd', DateTime.fromMillisecondsSinceEpoch(3), name: 'dup.jpg'),
        _file('ca', DateTime.fromMillisecondsSinceEpoch(4),
            name: 'arch.jpg', archived: true),
        _file('only', DateTime.fromMillisecondsSinceEpoch((_base + 600) * 1000)),
      ]);
      final out = mergeFeed(
        assets: assets,
        index: index,
        fileItemIdFor: (id) => id == 'linked' ? 'cl' : null,
      );
      expect(out.map(_sig).toList(), [
        'null|only',
        'linked|cl',
        'byname|cn',
        'ambiguous|null',
        'ambiguous2|null',
        'null|cd', // cloud-only: its name is ambiguous on the device side
      ]);
      // 'arch' matched an archived cloud file by name: hidden entirely.
      expect(out.any((e) => e.asset?.id == 'arch'), isFalse);
      expect(out.any((e) => e.fileItem?.id == 'ca'), isFalse);
    });

    test('entries carry precomputed date and thumb key', () {
      final out = mergeFeed(
        assets: [_asset('d1', 123, modSec: 456)],
        index: FileIndex(files: [_file('c1', DateTime.utc(2026, 1, 1))]),
        fileItemIdFor: (_) => null,
      );
      final dev = out.firstWhere((e) => e.asset != null);
      expect(dev.effectiveDateMs, (_base + 123) * 1000);
      expect(dev.thumbKey, deviceThumbKey('d1', 456));
      final cloud = out.firstWhere((e) => e.asset == null);
      expect(cloud.thumbKey, 'c1');
      expect(
          cloud.effectiveDateMs, DateTime.utc(2026, 1, 1).millisecondsSinceEpoch);
    });

    test('a matched device entry uses the cloud id as thumb key', () {
      final out = mergeFeed(
        assets: [_asset('d1', 123)],
        index: FileIndex(files: [_file('c1', DateTime.utc(2026, 1, 1))]),
        fileItemIdFor: (_) => 'c1',
      );
      expect(out.single.thumbKey, 'c1');
    });
  });

  group('sameFeed', () {
    test('same entries -> true; a different link or asset -> false', () {
      final a = _asset('d1', 100);
      final f = _file('c1', DateTime.fromMillisecondsSinceEpoch(1000));
      final x = [GalleryEntry(asset: a, fileItem: f)];
      final y = [GalleryEntry(asset: a, fileItem: f)];
      expect(sameFeed(x, y), isTrue);
      expect(sameFeed(x, [GalleryEntry(asset: a)]), isFalse);
      expect(sameFeed(x, [GalleryEntry(asset: _asset('d2', 100), fileItem: f)]),
          isFalse);
      expect(sameFeed(x, [...y, ...y]), isFalse);
    });
  });

  group('thumb keys', () {
    test('sha1 matches the standard vectors', () {
      expect(sha1HexForTesting([]), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect(sha1HexForTesting('abc'.codeUnits),
          'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(
          sha1HexForTesting(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'
                  .codeUnits),
          '84983e441c3bd26ebaae4aa1f95129e5e54670f1');
    });

    test('device key shape and sensitivity to modified time', () {
      final k = deviceThumbKey('12345', 99);
      expect(RegExp(r'^a_[0-9a-f]{20}_99$').hasMatch(k), isTrue);
      expect(deviceThumbKey('12345', 100), isNot(k));
      expect(deviceThumbKey('12346', 99), isNot(k));
      expect(deviceThumbKey('12345', 99), k);
    });
  });

  group('groupEntriesByMonth cache', () {
    test('same list instance -> same result instance', () {
      final list = [GalleryEntry(fileItem: _file('a', DateTime(2026, 10, 15)))];
      expect(identical(groupEntriesByMonth(list), groupEntriesByMonth(list)),
          isTrue);
    });
  });
}
