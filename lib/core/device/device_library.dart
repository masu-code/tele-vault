import 'dart:async';

import 'package:photo_manager/photo_manager.dart';

/// Thin seam over the photo_manager list calls so [DeviceLibrary]'s scan
/// logic can be tested with a fake source (no platform channel).
abstract class DeviceAssetSource {
  /// Total number of assets in the virtual "all" album.
  Future<int> allCount();

  /// One page of the "all" album, newest first by create date. May be shorter
  /// than [size] when assets disappeared mid-scan.
  Future<List<AssetEntity>> allPage(int page, int size);

  /// Assets of the "all" album whose update time is at or after [since]
  /// (any order).
  Future<List<AssetEntity>> allUpdatedSince(DateTime since);

  Future<int> albumCount(String albumId);

  /// One page of an album, newest first by create date.
  Future<List<AssetEntity>> albumPage(String albumId, int page, int size);
}

/// [DeviceAssetSource] backed by photo_manager.
class PhotoManagerAssetSource implements DeviceAssetSource {
  static final _type = RequestType.image | RequestType.video;

  static FilterOptionGroup _filter({DateTimeCond? updateTimeCond}) =>
      FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
        updateTimeCond: updateTimeCond,
      );

  AssetPathEntity? _allPath;
  final Map<String, AssetPathEntity> _albumPaths = {};

  Future<AssetPathEntity?> _all() async {
    final cached = _allPath;
    if (cached != null) return cached;
    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      onlyAll: true,
      type: _type,
      filterOption: _filter(),
    );
    return _allPath = paths.isEmpty ? null : paths.first;
  }

  @override
  Future<int> allCount() async {
    // A fresh path object per count: the cached one would keep reporting the
    // count it was created with on some platform versions.
    _allPath = null;
    final path = await _all();
    return path == null ? 0 : await path.assetCountAsync;
  }

  @override
  Future<List<AssetEntity>> allPage(int page, int size) async {
    final path = await _all();
    if (path == null) return const [];
    return path.getAssetListPaged(page: page, size: size);
  }

  @override
  Future<List<AssetEntity>> allUpdatedSince(DateTime since) async {
    final paths = await PhotoManager.getAssetPathList(
      hasAll: true,
      onlyAll: true,
      type: _type,
      filterOption: _filter(
        updateTimeCond: DateTimeCond(
          min: since,
          max: DateTime.now().add(const Duration(days: 1)),
        ),
      ),
    );
    if (paths.isEmpty) return const [];
    final path = paths.first;
    final count = await path.assetCountAsync;
    if (count == 0) return const [];
    final out = <AssetEntity>[];
    const size = 500;
    for (var page = 0; page * size < count; page++) {
      out.addAll(await path.getAssetListPaged(page: page, size: size));
    }
    return out;
  }

  Future<AssetPathEntity> _album(String albumId) async =>
      _albumPaths[albumId] ??= await AssetPathEntity.fromId(
        albumId,
        filterOption: _filter(),
        type: _type,
      );

  @override
  Future<int> albumCount(String albumId) async {
    _albumPaths.remove(albumId);
    return (await _album(albumId)).assetCountAsync;
  }

  @override
  Future<List<AssetEntity>> albumPage(
    String albumId,
    int page,
    int size,
  ) async => (await _album(albumId)).getAssetListPaged(page: page, size: size);
}

/// The single owner of photo_manager list calls for the "all" library and for
/// per-album pending scans.
///
/// A scan used to load every asset of every enabled album on startup, on
/// every MediaStore change and on connectivity changes, and the Gallery feed
/// loaded the whole library again: thousands of `AssetEntity` maps decoded on
/// the UI isolate each time. Now the full list is loaded once in pages (with
/// an event-loop turn between pages), cached, and later changes only fetch
/// what was updated since the last scan.
class DeviceLibrary {
  DeviceLibrary({
    DeviceAssetSource? source,
    DateTime Function()? clock,
    this.pageSize = 500,
    this.fullWalkInterval = const Duration(hours: 6),
  }) : _source = source ?? PhotoManagerAssetSource(),
       _now = clock ?? DateTime.now;

  static final DeviceLibrary instance = DeviceLibrary();

  final DeviceAssetSource _source;
  final DateTime Function() _now;
  final int pageSize;

  /// How long a completed album walk keeps allowing [pendingFor] to stop at
  /// the first full page without pending assets. After that a full walk
  /// re-validates (an old-dated photo restored into an album sorts deep in a
  /// newest-first list and would otherwise never be seen).
  final Duration fullWalkInterval;

  /// Margin subtracted from the last scan time when asking for updated
  /// assets, so clock skew between app and MediaStore cannot drop a change.
  static const _updateMargin = Duration(minutes: 2);

  List<AssetEntity>? _assets;
  int _countAtScan = 0;
  // list length minus the platform's reported count at the last full scan;
  // lets the incremental path validate without assuming they are equal.
  int _countDelta = 0;
  DateTime? _lastScanAt;
  int _changeStamp = 0;
  int _seenStamp = 0;

  Future<void> _queue = Future<void>.value();
  Future<List<AssetEntity>>? _pendingPlain;

  final Map<String, DateTime> _albumWalkedAt = {};

  /// Tells the library the device's media changed (MediaStore notification).
  /// The next [all] fetches updated assets even if the count is unchanged.
  void markDirty() => _changeStamp++;

  /// Forgets everything cached: the next [all] is a full rescan and the next
  /// [pendingFor] a full walk (e.g. pull-to-refresh).
  void invalidate() {
    _assets = null;
    _albumWalkedAt.clear();
  }

  /// Every photo/video on the device, newest first. The same list instance is
  /// returned while nothing changed.
  Future<List<AssetEntity>> all({bool forceRescan = false}) {
    if (!forceRescan) {
      final inFlight = _pendingPlain;
      if (inFlight != null) return inFlight;
    }
    final run = _queue.then((_) => _load(forceRescan));
    _queue = run.then<void>((_) {}, onError: (_) {});
    if (!forceRescan) {
      _pendingPlain = run;
      run.then<void>((_) {}, onError: (_) {}).whenComplete(() {
        if (identical(_pendingPlain, run)) _pendingPlain = null;
      });
    }
    return run;
  }

  Future<List<AssetEntity>> _load(bool force) async {
    final cached = _assets;
    if (force || cached == null) return _fullScan();

    final startedAt = _now();
    final stamp = _changeStamp;
    final count = await _source.allCount();
    if (count < _countAtScan) return _fullScan();
    if (count == _countAtScan && stamp == _seenStamp) return cached;

    final since = _lastScanAt!.subtract(_updateMargin);
    final updated = await _source.allUpdatedSince(since);
    final byId = <String, int>{};
    for (var i = 0; i < cached.length; i++) {
      byId[cached[i].id] = i;
    }
    var merged = cached;
    var copied = false;
    var changed = false;
    var inserted = false;
    for (final u in updated) {
      final at = byId[u.id];
      if (at == null) {
        if (!copied) {
          merged = List<AssetEntity>.of(cached);
          copied = true;
        }
        byId[u.id] = merged.length;
        merged.add(u);
        changed = true;
        inserted = true;
      } else if (merged[at].modifiedDateSecond != u.modifiedDateSecond ||
          merged[at].createDateSecond != u.createDateSecond) {
        if (!copied) {
          merged = List<AssetEntity>.of(cached);
          copied = true;
        }
        merged[at] = u;
        changed = true;
        if (merged[at].createDateSecond != cached[at].createDateSecond) {
          inserted = true; // position may change: re-sort
        }
      }
    }

    if (merged.length != count + _countDelta) return _fullScan();

    if (inserted) merged = _sortedNewestFirst(merged);
    _countAtScan = count;
    _lastScanAt = startedAt;
    _seenStamp = stamp;
    if (!changed) return cached;
    return _assets = merged;
  }

  List<AssetEntity> _sortedNewestFirst(List<AssetEntity> list) {
    // Dart's List.sort is not stable: decorate with the index.
    final order = List<int>.generate(list.length, (i) => i);
    order.sort((a, b) {
      final da = list[a].createDateSecond ?? 0;
      final db = list[b].createDateSecond ?? 0;
      return da != db ? db.compareTo(da) : a.compareTo(b);
    });
    return [for (final i in order) list[i]];
  }

  Future<List<AssetEntity>> _fullScan() async {
    final startedAt = _now();
    final stamp = _changeStamp;
    final count = await _source.allCount();
    final out = <AssetEntity>[];
    if (count > 0) {
      for (var page = 0; ; page++) {
        final chunk = await _source.allPage(page, pageSize);
        out.addAll(chunk);
        if (chunk.isEmpty || (page + 1) * pageSize >= count) break;
        // Let the UI isolate breathe between pages.
        await Future<void>.delayed(Duration.zero);
      }
    }
    _countAtScan = count;
    _countDelta = out.length - count;
    _lastScanAt = startedAt;
    _seenStamp = stamp;
    return _assets = out;
  }

  /// Assets of [albumIds] that are not uploaded yet ([isUploaded] says so),
  /// newest first within each album. Albums are walked in pages; once an album
  /// has had a complete walk (within [fullWalkInterval]) the walk stops at the
  /// first full page with nothing pending, because everything older was
  /// already seen as uploaded.
  Future<List<AssetEntity>> pendingFor(
    Set<String> albumIds,
    bool Function(String id) isUploaded,
  ) async {
    final out = <AssetEntity>[];
    final seen = <String>{};
    for (final albumId in albumIds) {
      final startedAt = _now();
      final count = await _source.albumCount(albumId);
      final walked = _albumWalkedAt[albumId];
      final canStopEarly =
          walked != null && startedAt.difference(walked) < fullWalkInterval;
      var complete = false;
      if (count == 0) {
        complete = true;
      } else {
        for (var page = 0; ; page++) {
          final chunk = await _source.albumPage(albumId, page, pageSize);
          var pageHadPending = false;
          for (final a in chunk) {
            if (isUploaded(a.id)) continue;
            pageHadPending = true;
            if (seen.add(a.id)) out.add(a);
          }
          if (chunk.isEmpty || (page + 1) * pageSize >= count) {
            complete = true;
            break;
          }
          if (canStopEarly && chunk.length >= pageSize && !pageHadPending) {
            break;
          }
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (complete) _albumWalkedAt[albumId] = startedAt;
    }
    return out;
  }
}
