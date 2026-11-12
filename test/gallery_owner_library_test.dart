import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/services/gallery_feed_service.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// A synthetic library shaped like the one behind the "month sections" report:
// ~6000 items, ~2500 on the device (part of them already uploaded) and ~3500
// cloud-only photos from an old Google Photos export, all uploaded during a
// few sessions in June 2026. The export's file names carry the capture date
// (IMG_YYYYMMDD_HHMMSS, PXL_..., WhatsApp ..., Screenshot_...), the index only
// has the upload time in `created_at`.

String _two(int n) => n.toString().padLeft(2, '0');

String _compact(DateTime d) =>
    '${d.year}${_two(d.month)}${_two(d.day)}_${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';

String _dashed(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// An export-style file name whose embedded date is [d] (local wall clock).
String _nameFor(DateTime d, int i) {
  switch (i % 8) {
    case 0:
      return 'IMG_${_compact(d)}.jpg';
    case 1:
      return 'PXL_${_compact(d)}123.jpg';
    case 2:
      return 'VID_${_compact(d)}.mp4';
    case 3:
      return '${_compact(d)}.jpg';
    case 4:
      return 'Screenshot_${_dashed(d)}-${_two(d.hour)}-${_two(d.minute)}-${_two(d.second)}-123_com.app.jpg';
    case 5:
      return 'WhatsApp Image ${_dashed(d)} at ${_two(d.hour)}.${_two(d.minute)}.${_two(d.second)}.jpeg';
    case 6:
      return 'IMG-${d.year}${_two(d.month)}${_two(d.day)}-WA${(i % 9999).toString().padLeft(4, '0')}.jpg';
    default:
      return 'signal-${_dashed(d)}-${_two(d.hour)}${_two(d.minute)}${_two(d.second)}.jpg';
  }
}

FileItem _file(String id, String name, DateTime createdAt) => FileItem(
      id: id,
      name: name,
      folderId: null,
      totalSize: 100,
      mimeType: name.endsWith('.mp4') ? 'video/mp4' : 'image/jpeg',
      createdAt: createdAt,
      parts: const [FilePart(messageId: 1, part: 0, size: 100)],
    );

class _Library {
  _Library(this.assets, this.index, this.links, this.takenById);
  final List<AssetEntity> assets;
  final FileIndex index;
  final Map<String, String> links;

  /// Expected capture time of every cloud-only item.
  final Map<String, DateTime> takenById;
}

_Library _ownerLibrary() {
  final rnd = Random(7);
  final assets = <AssetEntity>[];
  final files = <FileItem>[];
  final links = <String, String>{};
  final takenById = <String, DateTime>{};

  // Upload sessions: four evenings in June 2026 (UTC, as uploadFile stores it).
  final sessions = [
    DateTime.utc(2026, 6, 20, 22),
    DateTime.utc(2026, 6, 22, 23),
    DateTime.utc(2026, 6, 25, 21),
    DateTime.utc(2026, 6, 28, 20),
  ];

  // 2500 device photos taken between July 2025 and early November 2026.
  final deviceStart = DateTime(2025, 7, 1).millisecondsSinceEpoch;
  final deviceEnd = DateTime(2026, 11, 5).millisecondsSinceEpoch;
  for (var i = 0; i < 2500; i++) {
    final ms = deviceStart + rnd.nextInt((deviceEnd - deviceStart) ~/ 1000) * 1000;
    final taken = DateTime.fromMillisecondsSinceEpoch(ms);
    final id = 'd$i';
    assets.add(AssetEntity(
      id: id,
      typeInt: 1,
      width: 10,
      height: 10,
      title: 'IMG_${_compact(taken)}_$i.jpg',
      createDateSecond: ms ~/ 1000,
      modifiedDateSecond: ms ~/ 1000,
    ));
    // A third of them are already backed up (linked in the registry).
    if (i % 3 == 0) {
      final fid = 'u$i';
      files.add(_file(fid, 'IMG_${_compact(taken)}_$i.jpg',
          sessions[i % 4].add(Duration(seconds: i))));
      links[id] = fid;
    }
  }

  // 3500 cloud-only photos from the export, taken 2012..2024.
  final cloudStart = DateTime(2012, 1, 1).millisecondsSinceEpoch;
  final cloudEnd = DateTime(2024, 12, 31).millisecondsSinceEpoch;
  for (var i = 0; i < 3500; i++) {
    final ms = cloudStart + rnd.nextInt((cloudEnd - cloudStart) ~/ 1000) * 1000;
    final taken = DateTime.fromMillisecondsSinceEpoch(ms);
    final id = 'c$i';
    // WhatsApp's IMG-YYYYMMDD-WA names carry only the day.
    takenById[id] = i % 8 == 6 ? DateTime(taken.year, taken.month, taken.day) : taken;
    files.add(_file(id, _nameFor(taken, i),
        sessions[i % 4].add(Duration(seconds: i))));
  }
  files.shuffle(rnd);
  return _Library(assets, FileIndex(files: files), links, takenById);
}

void main() {
  final lib = _ownerLibrary();
  final feed = mergeFeed(
    assets: lib.assets,
    index: lib.index,
    fileItemIdFor: (id) => lib.links[id],
  );
  final groups = groupEntriesByMonth(feed);

  test('the library has the expected shape', () {
    expect(feed.length, 6000);
    expect(feed.where((e) => e.asset == null).length, 3500);
  });

  test('every cloud-only photo sits in the month it was taken', () {
    var wrong = 0;
    for (final g in groups) {
      for (final e in g.entries) {
        if (e.asset != null) continue;
        final taken = lib.takenById[e.fileItem!.id]!;
        if (taken.year != g.month.year || taken.month != g.month.month) wrong++;
      }
    }
    expect(wrong, 0, reason: '$wrong of 3500 cloud-only photos are filed under '
        'another month (their upload month)');
  });

  test('no single month section swallows the library', () {
    final biggest = groups.map((g) => g.entries.length).reduce(max);
    expect(biggest, lessThan(feed.length ~/ 10),
        reason: 'one section holds $biggest of ${feed.length} items');
  });

  test('each month is exactly one section, newest first', () {
    final months = [for (final g in groups) monthLabel(g.month)];
    expect(months.toSet().length, months.length,
        reason: 'repeated sections: ${months.where((m) => months.where((x) => x == m).length > 1).toSet()}');
    for (var i = 1; i < groups.length; i++) {
      expect(groups[i].month.isBefore(groups[i - 1].month), isTrue);
    }
  });

  test('sort key and month key agree for every entry', () {
    for (var i = 1; i < feed.length; i++) {
      expect(feed[i].effectiveDateMs <= feed[i - 1].effectiveDateMs, isTrue);
    }
    for (final g in groups) {
      for (final e in g.entries) {
        final d = DateTime.fromMillisecondsSinceEpoch(e.effectiveDateMs);
        expect(DateTime(d.year, d.month), g.month);
      }
    }
  });
}
