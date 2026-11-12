import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

// Uses the local DateTime constructor (not DateTime.parse with a 'Z' suffix)
// so effectiveDate.toLocal() is a no-op — avoids the test's month boundaries
// shifting depending on the machine's timezone offset from UTC.
FileItem _file(String id, DateTime createdAt) => FileItem(
      id: id,
      name: '$id.jpg',
      folderId: null,
      totalSize: 100,
      mimeType: 'image/jpeg',
      createdAt: createdAt,
      parts: const [FilePart(messageId: 1, part: 0, size: 100)],
    );

void main() {
  group('groupEntriesByMonth', () {
    test('empty input yields no groups', () {
      expect(groupEntriesByMonth([]), isEmpty);
    });

    test('single entry yields one group with that entry', () {
      final entry = GalleryEntry(fileItem: _file('a', DateTime(2026, 10, 15)));
      final groups = groupEntriesByMonth([entry]);
      expect(groups, hasLength(1));
      expect(groups.single.entries, [entry]);
      expect(groups.single.month, DateTime(2026, 10));
    });

    test('buckets consecutive same-month entries together', () {
      final a = GalleryEntry(fileItem: _file('a', DateTime(2026, 10, 15)));
      final b = GalleryEntry(fileItem: _file('b', DateTime(2026, 10, 1)));
      final groups = groupEntriesByMonth([a, b]);
      expect(groups, hasLength(1));
      expect(groups.single.entries, [a, b]);
    });

    test('starts a new group exactly at a month boundary', () {
      final oct = GalleryEntry(fileItem: _file('a', DateTime(2026, 10, 1)));
      final sep = GalleryEntry(fileItem: _file('b', DateTime(2026, 9, 30)));
      final groups = groupEntriesByMonth([oct, sep]);
      expect(groups, hasLength(2));
      expect(groups[0].month, DateTime(2026, 10));
      expect(groups[0].entries, [oct]);
      expect(groups[1].month, DateTime(2026, 9));
      expect(groups[1].entries, [sep]);
    });

    test('starts a new group across a year boundary', () {
      final jan = GalleryEntry(fileItem: _file('a', DateTime(2026, 1, 1)));
      final dec = GalleryEntry(fileItem: _file('b', DateTime(2025, 12, 31)));
      final groups = groupEntriesByMonth([jan, dec]);
      expect(groups, hasLength(2));
      expect(groups[0].month, DateTime(2026, 1));
      expect(groups[1].month, DateTime(2025, 12));
    });
  });

  group('duplicate month guard', () {
    test('a month that reappears joins its existing group, with one TVDIAG',
        () {
      final oct1 = GalleryEntry(fileItem: _file('a', DateTime(2026, 10, 20)));
      final sep = GalleryEntry(fileItem: _file('b', DateTime(2026, 9, 5)));
      final oct2 = GalleryEntry(fileItem: _file('c', DateTime(2026, 10, 2)));
      final oct3 = GalleryEntry(fileItem: _file('d', DateTime(2026, 10, 1)));
      final logs = <String>[];
      final prev = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      addTearDown(() => debugPrint = prev);

      // Deliberately NOT sorted by date: october comes back after september.
      final groups = groupEntriesByMonth([oct1, sep, oct2, oct3]);

      expect(groups, hasLength(2));
      expect(groups[0].month, DateTime(2026, 10));
      expect(groups[0].entries, [oct1, oct2, oct3]);
      expect(groups[1].month, DateTime(2026, 9));
      expect(groups[1].entries, [sep]);
      expect(
        logs.where((l) => l.startsWith('TVDIAG: gallery duplicate month group')),
        hasLength(1),
      );
    });

    test('sorted input logs nothing', () {
      final logs = <String>[];
      final prev = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      addTearDown(() => debugPrint = prev);
      groupEntriesByMonth([
        GalleryEntry(fileItem: _file('a', DateTime(2026, 10, 20))),
        GalleryEntry(fileItem: _file('b', DateTime(2026, 9, 5))),
      ]);
      expect(logs.where((l) => l.contains('TVDIAG')), isEmpty);
    });
  });

  group('monthLabel', () {
    test('formats month and year in English', () {
      expect(monthLabel(DateTime(2026, 10)), 'October 2026');
      expect(monthLabel(DateTime(2025, 1)), 'January 2025');
      expect(monthLabel(DateTime(2025, 12)), 'December 2025');
    });
  });

  group('monthHeaderLabel', () {
    test('omits the year only for the current year', () {
      expect(monthHeaderLabel(DateTime(2026, 11), 2026), 'November');
      expect(monthHeaderLabel(DateTime(2025, 6), 2026), 'June 2025');
    });
  });
}
