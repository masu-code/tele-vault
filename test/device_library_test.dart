import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:tele_vault/core/device/device_library.dart';

AssetEntity _asset(String id, int createSec, {int? modifiedSec}) => AssetEntity(
      id: id,
      typeInt: 1,
      width: 10,
      height: 10,
      title: '$id.jpg',
      createDateSecond: createSec,
      modifiedDateSecond: modifiedSec ?? createSec,
    );

/// In-memory stand-in for photo_manager. Counts the calls that would cross
/// the platform channel so tests can assert how much a scan costs.
class _FakeSource implements DeviceAssetSource {
  List<AssetEntity> all = [];
  final Map<String, List<AssetEntity>> albums = {};
  int countCalls = 0;
  int pageCalls = 0;
  int updatedCalls = 0;
  int albumPageCalls = 0;
  DateTime? lastSince;

  void setAll(List<AssetEntity> v) {
    all = [...v]
      ..sort((a, b) => b.createDateSecond!.compareTo(a.createDateSecond!));
  }

  @override
  Future<int> allCount() async {
    countCalls++;
    return all.length;
  }

  @override
  Future<List<AssetEntity>> allPage(int page, int size) async {
    pageCalls++;
    return all.skip(page * size).take(size).toList();
  }

  @override
  Future<List<AssetEntity>> allUpdatedSince(DateTime since) async {
    updatedCalls++;
    lastSince = since;
    return all
        .where((a) => a.modifiedDateSecond! * 1000 >= since.millisecondsSinceEpoch)
        .toList();
  }

  @override
  Future<int> albumCount(String albumId) async => albums[albumId]?.length ?? 0;

  @override
  Future<List<AssetEntity>> albumPage(
      String albumId, int page, int size) async {
    albumPageCalls++;
    return (albums[albumId] ?? []).skip(page * size).take(size).toList();
  }
}

void main() {
  late _FakeSource src;
  late DateTime now;
  late DeviceLibrary lib;

  int nowSec() => now.millisecondsSinceEpoch ~/ 1000;

  setUp(() {
    src = _FakeSource();
    now = DateTime.utc(2026, 11, 1, 12);
    lib = DeviceLibrary(source: src, clock: () => now, pageSize: 3);
  });

  // Old modified times (1000 + i seconds since the epoch) so "modified since
  // the last scan" only matches what a test changes explicitly.
  List<AssetEntity> library(int n) => [
        for (var i = 0; i < n; i++) _asset('a$i', 1000 + i),
      ];

  group('all()', () {
    test('full scan reads every page, newest first, and is cached', () async {
      src.setAll(library(10));
      final first = await lib.all();
      expect(first.map((a) => a.id).toList(),
          [for (var i = 9; i >= 0; i--) 'a$i']);
      expect(src.pageCalls, 4); // 3+3+3+1

      final second = await lib.all();
      expect(identical(second, first), isTrue);
      expect(src.pageCalls, 4);
      expect(src.updatedCalls, 0);
    });

    test('empty library yields an empty list without paging', () async {
      expect(await lib.all(), isEmpty);
      expect(src.pageCalls, 0);
    });

    test('concurrent plain calls share one scan', () async {
      src.setAll(library(10));
      final results = await Future.wait([lib.all(), lib.all(), lib.all()]);
      expect(identical(results[0], results[1]), isTrue);
      expect(identical(results[1], results[2]), isTrue);
      expect(src.pageCalls, 4);
    });

    test('added asset + markDirty is fetched incrementally (no full scan)',
        () async {
      src.setAll(library(10));
      final first = await lib.all();

      now = now.add(const Duration(minutes: 10));
      src.setAll([...src.all, _asset('new', 5000, modifiedSec: nowSec())]);
      lib.markDirty();
      final second = await lib.all();

      expect(src.pageCalls, 4, reason: 'no full rescan');
      expect(src.updatedCalls, 1);
      expect(second.first.id, 'new');
      expect(second.length, 11);
      expect(identical(second, first), isFalse);
    });

    test('count increase without markDirty is also picked up', () async {
      src.setAll(library(5));
      await lib.all();
      now = now.add(const Duration(minutes: 5));
      src.setAll([...src.all, _asset('new', 5000, modifiedSec: nowSec())]);
      final next = await lib.all();
      expect(next.first.id, 'new');
      expect(src.updatedCalls, 1);
    });

    test('dirty with nothing actually changed keeps the same instance',
        () async {
      src.setAll(library(5));
      final first = await lib.all();
      lib.markDirty();
      final second = await lib.all();
      expect(identical(first, second), isTrue);
      expect(src.updatedCalls, 1);
      // the dirty flag was consumed
      await lib.all();
      expect(src.updatedCalls, 1);
    });

    test('an edited asset replaces its cached copy', () async {
      src.setAll(library(5));
      await lib.all();
      now = now.add(const Duration(minutes: 5));
      src.setAll([
        for (final a in src.all)
          a.id == 'a2' ? _asset('a2', 1002, modifiedSec: nowSec()) : a,
      ]);
      lib.markDirty();
      final next = await lib.all();
      expect(next.firstWhere((a) => a.id == 'a2').modifiedDateSecond, nowSec());
      expect(next.length, 5);
      expect(src.pageCalls, 2, reason: 'no full rescan');
    });

    test('count going down forces a full rescan', () async {
      src.setAll(library(10));
      await lib.all();
      src.setAll(src.all.where((a) => a.id != 'a3').toList());
      final next = await lib.all();
      expect(next.length, 9);
      expect(next.any((a) => a.id == 'a3'), isFalse);
      expect(src.pageCalls, 4 + 3); // 9 assets / 3 per page
    });

    test('delete + add with the same count fails validation -> full rescan',
        () async {
      src.setAll(library(10));
      await lib.all();
      now = now.add(const Duration(minutes: 5));
      src.setAll([
        ...src.all.where((a) => a.id != 'a3'),
        _asset('fresh', 4000, modifiedSec: nowSec()),
      ]);
      lib.markDirty();
      final next = await lib.all();
      expect(next.any((a) => a.id == 'a3'), isFalse);
      expect(next.first.id, 'fresh');
      expect(src.pageCalls, 4 + 4);
    });

    test('forceRescan and invalidate re-read everything', () async {
      src.setAll(library(10));
      await lib.all();
      await lib.all(forceRescan: true);
      expect(src.pageCalls, 8);

      lib.invalidate();
      await lib.all();
      expect(src.pageCalls, 12);
    });

    test('updated-since query keeps a safety margin before the last scan',
        () async {
      src.setAll(library(3));
      await lib.all();
      final scanAt = now;
      now = now.add(const Duration(minutes: 10));
      lib.markDirty();
      await lib.all();
      expect(src.lastSince!.isBefore(scanAt), isTrue);
    });
  });

  group('pendingFor()', () {
    // album of 10 assets, newest first
    List<AssetEntity> album() =>
        [for (var i = 9; i >= 0; i--) _asset('a$i', 1000 + i)];

    test('first walk is complete, later walks stop at the first clean page',
        () async {
      src.albums['alb'] = album();
      final uploaded = <String>{for (var i = 0; i < 9; i++) 'a$i'};

      final first = await lib.pendingFor({'alb'}, uploaded.contains);
      expect(first.map((a) => a.id), ['a9']);
      expect(src.albumPageCalls, 4);

      src.albumPageCalls = 0;
      final second = await lib.pendingFor({'alb'}, uploaded.contains);
      expect(second.map((a) => a.id), ['a9']);
      // page 0 has the pending one, page 1 is full and clean -> stop
      expect(src.albumPageCalls, 2);
    });

    test('a deep pending asset is only found by the next full walk', () async {
      src.albums['alb'] = album();
      final uploaded = <String>{for (var i = 0; i < 10; i++) 'a$i'};
      expect(await lib.pendingFor({'alb'}, uploaded.contains), isEmpty);

      // an old-dated photo shows up deep in the list
      uploaded.remove('a0');
      src.albumPageCalls = 0;
      expect(await lib.pendingFor({'alb'}, uploaded.contains), isEmpty,
          reason: 'early stop at page 0 (documented trade-off)');
      expect(src.albumPageCalls, 1);

      now = now.add(const Duration(hours: 7));
      final later = await lib.pendingFor({'alb'}, uploaded.contains);
      expect(later.map((a) => a.id), ['a0']);
    });

    test('invalidate forces a full walk', () async {
      src.albums['alb'] = album();
      final uploaded = <String>{for (var i = 0; i < 10; i++) 'a$i'};
      await lib.pendingFor({'alb'}, uploaded.contains);
      uploaded.remove('a0');
      lib.invalidate();
      final found = await lib.pendingFor({'alb'}, uploaded.contains);
      expect(found.map((a) => a.id), ['a0']);
    });

    test('merges albums, no duplicates, empty album is fine', () async {
      src.albums['x'] = [_asset('1', 30), _asset('2', 20)];
      src.albums['y'] = [_asset('2', 20), _asset('3', 10)];
      src.albums['z'] = [];
      final found = await lib.pendingFor({'x', 'y', 'z'}, (_) => false);
      expect(found.map((a) => a.id), ['1', '2', '3']);
    });

    test('nothing pending returns empty', () async {
      src.albums['alb'] = album();
      expect(await lib.pendingFor({'alb'}, (_) => true), isEmpty);
    });
  });
}
