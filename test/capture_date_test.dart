import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/upload/upload_plan.dart';
import 'package:tele_vault/core/upload/upload_service.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/models/capture_date.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

final _now = DateTime(2026, 11, 11, 12);

int? _parse(String name) => captureDateFromName(name, now: _now);

int _local(int y, int mo, int d, [int h = 0, int mi = 0, int s = 0]) =>
    DateTime(y, mo, d, h, mi, s).millisecondsSinceEpoch;

FileItem _file(String name, {Map<String, dynamic> extra = const {}}) =>
    FileItem(
      id: 'id-$name',
      name: name,
      folderId: null,
      totalSize: 1,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026, 6, 20, 22),
      parts: const [FilePart(messageId: 1, part: 0, size: 1)],
      extra: extra,
    );

void main() {
  group('captureDateFromName', () {
    test('camera and app patterns', () {
      expect(_parse('IMG_20190505_143022.jpg'), _local(2019, 5, 5, 14, 30, 22));
      expect(_parse('VID_20180102_030405.mp4'), _local(2018, 1, 2, 3, 4, 5));
      expect(_parse('PXL_20231224_235959123.jpg'),
          _local(2023, 12, 24, 23, 59, 59));
      expect(_parse('MVIMG_20200101_000001.jpg'), _local(2020, 1, 1, 0, 0, 1));
      expect(_parse('20170704_101112.jpg'), _local(2017, 7, 4, 10, 11, 12));
      expect(_parse('20170704_101112(1).jpg'), _local(2017, 7, 4, 10, 11, 12));
      expect(_parse('IMG_20190505_143022-edited.jpg'),
          _local(2019, 5, 5, 14, 30, 22));
      expect(_parse('Screenshot_20210309-081500.png'),
          _local(2021, 3, 9, 8, 15));
      expect(_parse('Screenshot_20210309_081500_com.app.jpg'),
          _local(2021, 3, 9, 8, 15));
      expect(_parse('Screenshot_2021-03-09-08-15-00-123_com.app.jpg'),
          _local(2021, 3, 9, 8, 15));
      expect(_parse('signal-2022-11-30-191817.jpg'),
          _local(2022, 11, 30, 19, 18, 17));
      expect(_parse('signal-2022-11-30-19-18-17-555.jpg'),
          _local(2022, 11, 30, 19, 18, 17));
      expect(_parse('WhatsApp Image 2020-02-14 at 21.05.33.jpeg'),
          _local(2020, 2, 14, 21, 5, 33));
      expect(_parse('WhatsApp Image 2020-02-14 at 9.05.33 PM.jpeg'),
          _local(2020, 2, 14, 21, 5, 33));
      expect(_parse('WhatsApp Image 2020-02-14 at 12.05.33 AM.jpeg'),
          _local(2020, 2, 14, 0, 5, 33));
      expect(_parse('WhatsApp Video 2020-02-14 at 21.05.33.mp4'),
          _local(2020, 2, 14, 21, 5, 33));
      expect(_parse('IMG-20150817-WA0003.jpg'), _local(2015, 8, 17));
      expect(_parse('VID-20150817-WA0003.mp4'), _local(2015, 8, 17));
      expect(_parse('img_20190505_143022.JPG'), _local(2019, 5, 5, 14, 30, 22));
    });

    test('no recognized date -> null', () {
      for (final name in [
        'image.jpg',
        'IMG_1234.jpg',
        'DSC00042.JPG',
        'photo_2019.jpg',
        'holiday 20190505_143022.jpg', // date not at the start
        '1699999999999.jpg',
        '',
      ]) {
        expect(_parse(name), isNull, reason: name);
      }
    });

    test('implausible dates are rejected', () {
      expect(_parse('IMG_19991231_235959.jpg'), isNull, reason: 'before 2000');
      expect(_parse('IMG_20000101_000000.jpg'), _local(2000, 1, 1));
      expect(_parse('IMG_20261112_000000.jpg'), isNull, reason: 'future');
      expect(_parse('IMG_20261111_115959.jpg'), _local(2026, 11, 11, 11, 59, 59));
      expect(_parse('IMG_20230230_120000.jpg'), isNull, reason: 'Feb 30');
      expect(_parse('IMG_20231301_120000.jpg'), isNull, reason: 'month 13');
      expect(_parse('IMG_20230101_246000.jpg'), isNull, reason: 'hour 24');
      expect(_parse('IMG_20230101_126000.jpg'), isNull, reason: 'minute 60');
      expect(_parse('WhatsApp Image 2020-02-14 at 13.05.33 PM.jpeg'), isNull);
    });
  });

  group('cloudCaptureMs', () {
    test('stored taken_at wins over the name unless they differ by > 36 h, '
        'the name over createdAt', () {
      final stored = _local(2019, 5, 5, 20);
      expect(
          cloudCaptureMs(_file('IMG_20190505_143022.jpg',
              extra: {takenAtKey: stored})),
          stored,
          reason: 'same day: the stored value stays');
      expect(
          cloudCaptureMs(_file('IMG_20190505_143022.jpg',
              extra: {takenAtKey: _local(2019, 5, 6, 23)})),
          _local(2019, 5, 6, 23),
          reason: 'about 32 h apart: still the stored value');
      expect(
          cloudCaptureMs(_file('IMG_20190505_143022.jpg',
              extra: {takenAtKey: _local(2024, 11, 2)})),
          _local(2019, 5, 5, 14, 30, 22),
          reason: 'a migration-day taken_at loses to the name');
      expect(cloudCaptureMs(_file('IMG_20190505_143022.jpg')),
          _local(2019, 5, 5, 14, 30, 22));
      expect(cloudCaptureMs(_file('image.jpg')),
          DateTime.utc(2026, 6, 20, 22).millisecondsSinceEpoch);
    });

    test('an invalid stored value falls back', () {
      expect(cloudCaptureMs(_file('image.jpg', extra: {takenAtKey: 'x'})),
          DateTime.utc(2026, 6, 20, 22).millisecondsSinceEpoch);
      expect(cloudCaptureMs(_file('image.jpg', extra: {takenAtKey: 0})),
          DateTime.utc(2026, 6, 20, 22).millisecondsSinceEpoch);
    });

    test('an implausible stored value is skipped, never throws in grouping',
        () {
      final created = DateTime.utc(2026, 6, 20, 22).millisecondsSinceEpoch;
      final nanos = DateTime(2024, 1, 5).microsecondsSinceEpoch * 1000;
      for (final bad in <num>[
        nanos,
        1e30,
        double.nan,
        _local(1999, 12, 31),
        _local(2036, 3, 1),
      ]) {
        final f = _file('image.jpg', extra: {takenAtKey: bad});
        expect(cloudCaptureMs(f), created, reason: '$bad');
        expect(() => groupEntriesByMonth([GalleryEntry(fileItem: f)]),
            returnsNormally);
      }
      // ...and falls through to the name when there is one.
      expect(
          cloudCaptureMs(_file('IMG_20190505_143022.jpg',
              extra: {takenAtKey: _local(2036, 3, 1)})),
          _local(2019, 5, 5, 14, 30, 22));
    });

    test('GalleryEntry sorts and groups a cloud-only item by it', () {
      final e = GalleryEntry(fileItem: _file('IMG_20190505_143022.jpg'));
      expect(e.effectiveDateMs, _local(2019, 5, 5, 14, 30, 22));
      expect(groupEntriesByMonth([e]).single.month, DateTime(2019, 5));
    });
  });

  group('resolveCaptureMs / device dates', () {
    final now = DateTime(2026, 11, 11, 12);

    test('name wins past 36 h, raw wins within it', () {
      const name = 'IMG-20240105-WA0012.jpg'; // 2024-01-05 00:00
      expect(resolveCaptureMs(_local(2026, 10, 1), name, now: now),
          _local(2024, 1, 5));
      expect(resolveCaptureMs(_local(2024, 1, 6, 10), name, now: now),
          _local(2024, 1, 6, 10),
          reason: '34 h');
      expect(resolveCaptureMs(_local(2024, 1, 7), name, now: now),
          _local(2024, 1, 5),
          reason: '48 h');
      expect(resolveCaptureMs(_local(2024, 1, 7), 'IMG_1234.JPG', now: now),
          _local(2024, 1, 7));
      expect(resolveCaptureMs(null, name, now: now), _local(2024, 1, 5));
      expect(resolveCaptureMs(null, 'IMG_1234.JPG', now: now), isNull);
    });

    test('bounds: year >= 2000, at most 1 day ahead', () {
      expect(plausibleCaptureMs(_local(1999, 12, 31, 23), now: now), isNull);
      expect(plausibleCaptureMs(_local(2000, 1, 1), now: now),
          _local(2000, 1, 1));
      expect(plausibleCaptureMs(_local(2026, 11, 12), now: now),
          _local(2026, 11, 12));
      expect(plausibleCaptureMs(_local(2026, 11, 13), now: now), isNull);
      expect(plausibleCaptureMs(1e30, now: now), isNull);
      expect(plausibleCaptureMs(double.nan, now: now), isNull);
    });

    AssetEntity asset(String id, int? createSec, {String? title}) =>
        AssetEntity(
          id: id,
          typeInt: 1,
          width: 1,
          height: 1,
          createDateSecond: createSec,
          title: title,
        );

    test('device asset: name beats a DATE_ADDED fallback', () {
      final a = asset('a1', _local(2025, 3, 3) ~/ 1000,
          title: 'IMG-20240105-WA0012.jpg');
      expect(deviceCaptureMs(a), _local(2024, 1, 5));
      expect(assetTakenAtMs(a), _local(2024, 1, 5));
      expect(GalleryEntry(asset: a).effectiveDateMs, _local(2024, 1, 5));
    });

    test('device asset: garbage dates fall through and never throw', () {
      // A date in nanoseconds, read as seconds.
      final nanos = DateTime(2024, 1, 5).microsecondsSinceEpoch * 1000;
      final huge = asset('a2', nanos);
      expect(deviceCaptureMs(huge), isNull);
      expect(assetTakenAtMs(huge), isNull);
      final e = GalleryEntry(asset: huge);
      expect(e.effectiveDateMs, 0);
      expect(() => groupEntriesByMonth([e]), returnsNormally);

      final future = asset('a3', _local(2036, 3, 1) ~/ 1000,
          title: 'IMG_20230404_101010.jpg');
      expect(deviceCaptureMs(future), _local(2023, 4, 4, 10, 10, 10));

      final unknown = asset('a4', null);
      expect(deviceCaptureMs(unknown), isNull);
      expect(GalleryEntry(asset: unknown).effectiveDateMs, 0);
    });
  });

  group('taken_at in the index JSON', () {
    test('round-trips, and an old index without it still loads', () {
      final ms = _local(2016, 9, 1, 8);
      final item = _file('a.jpg', extra: takenAtExtra(ms));
      final json = item.toJson();
      expect(json[takenAtKey], ms);
      final back = FileItem.fromJson(json);
      expect(back.extra[takenAtKey], ms);
      expect(cloudCaptureMs(back), ms);

      final old = Map<String, dynamic>.of(json)..remove(takenAtKey);
      final legacy = FileItem.fromJson(old);
      expect(legacy.extra, isEmpty);
      expect(legacy.toJson().containsKey(takenAtKey), isFalse);
    });

    test('takenAtExtra omits unknown dates', () {
      expect(takenAtExtra(null), isEmpty);
      expect(takenAtExtra(0), isEmpty);
    });

    test('uploadFile stores takenAtMs; without it nothing is added', () async {
      final tmp = await Directory.systemTemp.createTemp('tv_taken_at');
      addTearDown(() => tmp.delete(recursive: true));
      final file = File(p.join(tmp.path, 'sample.bin'));
      await file.writeAsBytes(List<int>.filled(100, 1));
      final service = UploadService.forTesting((
        RandomAccessFile raf,
        UploadSegment seg,
        String name,
        String mime,
        int totalSegments,
        void Function(int) onChunk, {
        Uint8List? thumbJpeg,
      }) async =>
          9);

      final ms = _local(2013, 2, 2, 2);
      final item = await service.uploadFile(file, takenAtMs: ms);
      expect(item.extra[takenAtKey], ms);
      // The worker isolate hands the item back as JSON: the date survives.
      expect(FileItem.fromJson(item.toJson()).extra[takenAtKey], ms);

      final none = await service.uploadFile(file);
      expect(none.toJson().containsKey(takenAtKey), isFalse);
    });
  });
}
