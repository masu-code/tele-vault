import 'package:flutter_test/flutter_test.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/services/undated_shape_diag.dart';
import 'package:tele_vault/models/capture_date.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

FileItem _file(String name) => FileItem(
      id: name,
      name: name,
      folderId: null,
      totalSize: 1,
      mimeType: 'video/mp4',
      createdAt: DateTime(2026, 11, 1),
      parts: const [FilePart(messageId: 1, part: 0, size: 1)],
    );

void main() {
  test('nameShape: letters -> A, digits -> 9, runs collapsed', () {
    expect(nameShape('IMG_20240105_142233.jpg'), 'A_9_9.A');
    expect(nameShape('20240105.mp4'), '9.A');
    expect(nameShape('video_2024-01-05_14-22-33.mp4'), 'A_9-9-9_9-9-9.A');
    expect(nameShape('WhatsApp Video 2024-01-05 at 14.22.33.mp4'),
        'A A 9-9-9 A 9.9.9.A');
    expect(nameShape('a1b2.MOV'), 'A9A9.A');
    expect(nameShape('Ñandú_7.jpg'), 'A_9.A');
    expect(nameShape('clip\u{1F600}.mp4'), 'A?.A');
    expect(nameShape(''), '');
    expect(nameShape('noext'), 'A');
    expect(nameShape('.hidden'), '.A');
    expect(nameShape('archive.tar.gz'), 'A.A.A');
    final long = nameShape(List.filled(100, 'a-').join());
    expect(long.length, 65);
    expect(long.endsWith('+'), isTrue);
  });

  test('undatedShapeReport: counts only cloud-only items dated by upload', () {
    final entries = [
      GalleryEntry(fileItem: _file('screen-rec-1.mp4')),
      GalleryEntry(fileItem: _file('screen-rec-2.mp4')),
      GalleryEntry(fileItem: _file('99.mp4')),
      // Dated by its name: not counted.
      GalleryEntry(fileItem: _file('VID_20240105_142233.mp4')),
      // Dated by a stored taken_at: not counted.
      GalleryEntry(
          fileItem: withTakenAt(_file('x.mp4'), 1700000000000)),
    ];
    final lines = undatedShapeReport(entries);
    expect(lines, [
      'TVDIAG: undated shape A-A-9.A n=2',
      'TVDIAG: undated shape 9.A n=1',
      'TVDIAG: undated total=3 of 5',
    ]);
    for (final l in lines) {
      expect(l.contains('screen'), isFalse);
    }
  });

  test('undatedShapeReport: top limit', () {
    // 20 distinct shapes: x, x-x, x-x-x, ... (the 20-group one twice).
    final entries = [
      for (var i = 0; i < 20; i++)
        GalleryEntry(fileItem: _file('${List.filled(i + 1, 'x').join('-')}.mp4')),
      GalleryEntry(fileItem: _file('${List.filled(20, 'y').join('-')}.mp4')),
    ];
    final lines = undatedShapeReport(entries, top: 15);
    expect(lines, hasLength(16));
    expect(lines.first, 'TVDIAG: undated shape ${List.filled(20, 'A').join('-')}.A n=2');
    expect(lines.last, 'TVDIAG: undated total=21 of 21');
  });
}
