import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:tele_vault/core/backup/headless_sync.dart';
import 'package:tele_vault/core/backup/transfer_notifications.dart';
import 'package:tele_vault/core/upload/upload_plan.dart';
import 'package:tele_vault/core/upload/upload_service.dart';
import 'package:tele_vault/models/file_index.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tv_core/codecs.dart' show PreviewCodec;
import 'package:workmanager/workmanager.dart' show ForegroundServiceType;

/// A 320x240 JPEG with a gradient, inside Telegram's thumb limits.
Uint8List _thumbJpeg() {
  final image = img.Image(width: 320, height: 240);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(x, y, x * 255 ~/ 320, y * 255 ~/ 240, 90);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

FileItem _item(String id, String name, int size) => FileItem(
      id: id,
      name: name,
      folderId: null,
      totalSize: size,
      mimeType: 'image/jpeg',
      createdAt: DateTime.utc(2026, 11, 1),
      parts: const [],
    );

/// Records every registry write a flush makes.
class _FakeRegistry {
  final commits = <List<UploadLink>>[];
  final unlinked = <String>[];
  int perItemWrites = 0; // markUploaded / linkLocalPath / linkFileItem

  Future<void> commitUploads(List<UploadLink> links) async {
    commits.add(List.of(links));
  }

  Future<void> unlinkFileItem(String id) async => unlinked.add(id);

  Future<void> markUploaded(String _) async => perItemWrites++;
  Future<void> linkLocalPath(String _, String _) async => perItemWrites++;
  Future<void> linkFileItem(String _, String _) async => perItemWrites++;
}

void main() {
  group('preview in the uploaded FileItem', () {
    late Directory tmp;
    late File file;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tv_upload_preview');
      file = File(p.join(tmp.path, 'sample.bin'));
      await file.writeAsBytes(List<int>.generate(3000, (i) => i & 0xFF));
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('the th1 preview computed from the thumb is stored in the item', () async {
      final thumb = _thumbJpeg();
      final hash = PreviewCodec.encodeJpeg(thumb);
      expect(hash, isNotNull, reason: 'headless path: pure-Dart preview');
      final wire = PreviewCodec.toWire(hash!);

      Uint8List? sentThumb;
      var segments = 0;
      final service = UploadService.forTesting((
        RandomAccessFile raf,
        UploadSegment seg,
        String name,
        String mime,
        int totalSegments,
        void Function(int) onChunk, {
        Uint8List? thumbJpeg,
      }) async {
        segments++;
        sentThumb = thumbJpeg;
        onChunk(seg.size);
        return 4242;
      });

      final item = await service.uploadFile(file, thumbJpeg: thumb, preview: wire);

      expect(segments, 1);
      expect(sentThumb, same(thumb), reason: 'the valid thumb goes to Telegram');
      expect(item.preview, wire);
      expect(item.parts.single.messageId, 4242);
      expect(item.totalSize, 3000);
      // The worker isolate hands the item back as JSON: the preview survives.
      expect(FileItem.fromJson(item.toJson()).preview, wire);
      expect(item.toJson()['preview'], wire);
    });

    test('an invalid preview string is dropped, the upload still succeeds', () async {
      final service = UploadService.forTesting((
        RandomAccessFile raf,
        UploadSegment seg,
        String name,
        String mime,
        int totalSegments,
        void Function(int) onChunk, {
        Uint8List? thumbJpeg,
      }) async =>
          7);

      final bad = await service.uploadFile(file, preview: 'th1:not-a-hash');
      expect(bad.preview, isNull);
      expect(bad.toJson().containsKey('preview'), isFalse);

      final none = await service.uploadFile(file);
      expect(none.preview, isNull);
    });
  });

  group('headless check vs foreground run', () {
    test('the dispatcher tells the two task names apart', () {
      expect(uploadSyncTaskName, isNot(uploadRunTaskName));
      expect(headlessJobFor(uploadSyncTaskName), HeadlessJob.check);
      expect(headlessJobFor(uploadRunTaskName), HeadlessJob.uploadRun);
      expect(headlessJobFor('something-else'), HeadlessJob.unknown);
    });

    test('nothing pending: no foreground run is scheduled, nothing runs', () async {
      var scheduled = 0, inline = 0;
      final outcome = await scheduleOrRunInline(
        pendingCount: 0,
        scheduleForegroundRun: () async => scheduled++,
        runInline: () async => inline++,
      );
      expect(outcome, HeadlessCheckOutcome.nothingToDo);
      expect((scheduled, inline), (0, 0));
    });

    test('pending: the foreground run is scheduled, no inline upload', () async {
      var scheduled = 0, inline = 0;
      final outcome = await scheduleOrRunInline(
        pendingCount: 3,
        scheduleForegroundRun: () async => scheduled++,
        runInline: () async => inline++,
      );
      expect(outcome, HeadlessCheckOutcome.scheduled);
      expect((scheduled, inline), (1, 0));
    });

    test('scheduling fails: the upload runs inline', () async {
      var inline = 0;
      final outcome = await scheduleOrRunInline(
        pendingCount: 3,
        scheduleForegroundRun: () async => throw Exception('INIT_REQUIRED'),
        runInline: () async => inline++,
      );
      expect(outcome, HeadlessCheckOutcome.ranInline);
      expect(inline, 1);
    });

    test('the foreground config uses the transfer notification id and channel', () {
      final c = headlessForegroundConfig();
      expect(c.notificationId, TransferNotifications.progressId);
      expect(c.notificationChannelId, TransferNotifications.channelId);
      expect(c.foregroundServiceType, ForegroundServiceType.dataSync);
      expect(inlineRunBudget < const Duration(minutes: 10), isTrue);
    });

    test('flush every 8 files or after 2 min with anything pending', () {
      expect(headlessFlushEvery, 8);
      expect(headlessFlushAfter, const Duration(minutes: 2));
      // Several flushes fit in the 10 min a worker gets without a foreground
      // service, so a stopped run loses at most one small batch.
      expect(headlessFlushAfter * 4 <= const Duration(minutes: 10), isTrue);
      expect(headlessFlushDue(0, const Duration(hours: 1)), isFalse);
      expect(headlessFlushDue(7, const Duration(seconds: 119)), isFalse);
      expect(headlessFlushDue(8, Duration.zero), isTrue);
      expect(headlessFlushDue(1, const Duration(minutes: 2)), isTrue);
    });

    test('batch: concurrent flushes are serialized, nothing written twice', () async {
      final writes = <List<int>>[];
      final gate = Completer<void>();
      final batch = HeadlessBatch<int, String>((u, h) async {
        writes.add(List.of(u));
        if (writes.length == 1) await gate.future;
      });
      batch.uploads.addAll([1, 2]);
      final first = batch.flush();
      await Future<void>.delayed(Duration.zero);
      // An upload finishes while the first write is in flight, and the stop
      // signal flushes at the same time.
      batch.uploads.add(3);
      final second = batch.flush();
      await Future<void>.delayed(Duration.zero);
      expect(writes, [
        [1, 2]
      ], reason: 'the second flush waits for the first');
      gate.complete();
      await Future.wait([first, second]);
      expect(writes, [
        [1, 2],
        [3]
      ]);
      expect(batch.uploads, isEmpty);
      await batch.flush();
      expect(writes.length, 2, reason: 'nothing pending: no write');
    });

    test('batch: a failed write keeps its items and does not block the next', () async {
      var fail = true;
      final written = <int>[];
      final batch = HeadlessBatch<int, String>((u, h) async {
        if (fail) throw StateError('offline');
        written.addAll(u);
      });
      batch.uploads.add(1);
      batch.hits.add('h');
      await expectLater(batch.flush(), throwsA(isA<StateError>()));
      expect(batch.uploads, [1]);
      expect(batch.hits, ['h']);
      fail = false;
      await batch.flush();
      expect(written, [1]);
      expect(batch.hits, isEmpty);
    });
  });

  group('flush registry writes', () {
    test('one commitUploads call (one transaction) for the whole batch', () async {
      final registry = _FakeRegistry();
      final kept1 = _item('id-kept-1', 'a.jpg', 10);
      final kept2 = _item('id-kept-2', 'b.jpg', 20);
      final droppedWithSurvivor = _item('id-dup', 'c.jpg', 30);
      final droppedNoSurvivor = _item('id-gone', 'd.jpg', 40);
      final survivor = _item('id-remote-c', 'c.jpg', 30);

      // What the save wrote: the rebase dropped two of the new files.
      final written = FileIndex.empty().addFiles([kept1, kept2, survivor]);

      final links = await commitFlushedUploads(
        written: written,
        uploaded: [
          (item: kept1, assetId: 'asset1', path: '/x/1'),
          (item: kept2, assetId: 'asset2', path: '/x/2'),
          (item: droppedWithSurvivor, assetId: 'asset3', path: '/x/3'),
          (item: droppedNoSurvivor, assetId: 'asset4', path: '/x/4'),
        ],
        alreadyInVault: [(assetId: 'asset5', fileItemId: 'id-remote-c', path: '/x/5')],
        droppedIds: ['id-dup', 'id-gone'],
        commitUploads: registry.commitUploads,
        unlinkFileItem: registry.unlinkFileItem,
      );

      expect(registry.commits, hasLength(1));
      expect(registry.perItemWrites, 0);
      expect(registry.commits.single, links);
      final byAsset = {for (final l in links) l.assetId: l.fileItemId};
      expect(byAsset, {
        'asset5': 'id-remote-c',
        'asset1': 'id-kept-1',
        'asset2': 'id-kept-2',
        // Same name and size as a file already in the vault: linked to it.
        'asset3': 'id-remote-c',
      });
      // No link ever points at a dropped id, and each is unlinked.
      expect(links.where((l) => l.fileItemId == 'id-dup' || l.fileItemId == 'id-gone'),
          isEmpty);
      expect(registry.unlinked, unorderedEquals(['id-dup', 'id-gone']));
    });

    test('an item missing from the written index is never linked to its own id', () async {
      final registry = _FakeRegistry();
      final lost = _item('id-lost', 'e.jpg', 50);
      final links = await commitFlushedUploads(
        written: FileIndex.empty(),
        uploaded: [(item: lost, assetId: 'asset6', path: '/x/6')],
        commitUploads: registry.commitUploads,
        unlinkFileItem: registry.unlinkFileItem,
      );
      expect(links, isEmpty);
      expect(registry.commits, isEmpty);
      expect(registry.perItemWrites, 0);
    });
  });
}
