import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:tv_core/codecs.dart';
import 'package:tv_core/models.dart' show FileItem, ThumbPackRef;

import '../download/download_service.dart';
import '../download/download_worker.dart';
import 'pack_installer.dart';
import 'preview_table.dart';
import 'server_thumb_batch.dart';
import 'thumb_encoder.dart';
import 'thumb_store.dart';

/// One thumbnail to produce. [key] is the ThumbStore key (see [ThumbKey]);
/// [file] is the cloud item, if any; [assetId] the device asset, if any (the
/// asset is resolved lazily, on the main isolate, only when work for the key
/// actually starts). [asset] is an optional already-resolved entity that saves
/// that lookup.
class ThumbRequest {
  const ThumbRequest({required this.key, this.file, this.assetId, this.asset});

  final String key;
  final FileItem? file;
  final String? assetId;
  final AssetEntity? asset;
}

/// Snapshot of what the prefetcher is doing (for diagnostics and UI hints).
@immutable
class PrefetchStatus {
  const PrefetchStatus({
    this.queued = 0,
    this.active = 0,
    this.packsPending = 0,
    this.failed = 0,
    this.paused = false,
  });

  /// Prioritized (on or near screen) keys still waiting for a thumbnail.
  final int queued;

  /// Jobs running right now (device, server batch, full download, pack).
  final int active;

  /// Packs not yet installed and not in backoff.
  final int packsPending;

  /// Keys waiting out a failure backoff.
  final int failed;

  final bool paused;

  @override
  bool operator ==(Object other) =>
      other is PrefetchStatus &&
      other.queued == queued &&
      other.active == active &&
      other.packsPending == packsPending &&
      other.failed == failed &&
      other.paused == paused;

  @override
  int get hashCode => Object.hash(queued, active, packsPending, failed, paused);
}

/// A device thumbnail as JPEG bytes (null: the asset is gone or has none).
typedef DeviceThumbFn = Future<Uint8List?> Function(ThumbRequest request);

/// Tiny ThumbHash of a JPEG (null on failure).
typedef PreviewFromJpegFn = Future<Uint8List?> Function(Uint8List jpeg);

/// Fetches Telegram's embedded thumbnails for a batch of messages.
typedef ServerThumbsFn = Future<List<ServerThumbResult>> Function(
    List<ServerThumbTarget> targets);

/// Downloads a whole cloud image and returns a thumbnail JPEG of it, or null
/// when the file cannot be turned into one (not an image, undecodable).
typedef FullThumbFn = Future<Uint8List?> Function(FileItem file);

typedef InstallPackFn = Future<PackInstallResult> Function(PackInstallArgs args);
typedef DiscoverPacksFn = Future<List<ThumbPackRef>> Function();

/// Fills the [ThumbStore] (and the [PreviewTable]) without the UI ever asking
/// the network or the platform for anything.
///
/// Sources for a key, in order:
///  1. the device asset, when the entry has one that still exists
///     (256 px JPEG q80 from photo_manager, pool of 2);
///  2. a thumbnail pack (TVTP) that contains it. Packs are installed whole,
///     one at a time, from `index.thumbPacks` plus the packs discovered in
///     Saved Messages once per session;
///  3. Telegram's embedded server thumbnails, in batches of at most 50 ids;
///  4. a full download plus downscale, images only.
///
/// Scheduling: keys the UI asked for ([prioritize], most recent first) run
/// first. The rest of the library is filled in the background (stage 1 and 3)
/// in feed order, only while not [pause]d. Stage 4 runs ONLY for prioritized
/// keys, and only once the packs have settled: the background download of
/// every old photo is the backfill job's business, not an automatic one.
///
/// A failure is never remembered as "no thumbnail": the key backs off 30 s,
/// 2 min, 10 min, then 1 h (in memory) and is retried. Only a definitive
/// "nothing to fetch" (a video without a server thumbnail, an undecodable
/// image, a device asset that is gone) marks a key `noSource` until the next
/// session or until the packs change.
class ThumbPrefetcher {
  ThumbPrefetcher({
    ThumbStore? store,
    PreviewTable? previews,
    DeviceThumbFn? deviceThumb,
    PreviewFromJpegFn? previewFromJpeg,
    ServerThumbsFn? serverThumbs,
    FullThumbFn? fullThumb,
    InstallPackFn? installPack,
    DiscoverPacksFn? discoverPacks,
    this.deviceConcurrency = 2,
    this.serverConcurrency = 2,
    this.fullConcurrency = 2,
    this.serverBatchSize = 50,
    this.backoff = defaultBackoff,
    DateTime Function()? now,
  })  : _store = store ?? ThumbStore.instance,
        _previews = previews ?? PreviewTable.instance,
        _deviceThumb = deviceThumb ?? _defaultDeviceThumb,
        _previewFromJpeg = previewFromJpeg ?? defaultPreviewFromJpeg,
        _serverThumbs = serverThumbs ?? _defaultServerThumbs,
        _fullThumb = fullThumb ?? _defaultFullThumb,
        _installPack = installPack ?? _defaultInstallPack,
        _discoverPacks = discoverPacks ?? _defaultDiscoverPacks,
        _now = now ?? DateTime.now;

  static final ThumbPrefetcher instance = ThumbPrefetcher();

  static const List<Duration> defaultBackoff = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 10),
    Duration(hours: 1),
  ];

  final ThumbStore _store;
  final PreviewTable _previews;
  final DeviceThumbFn _deviceThumb;
  final PreviewFromJpegFn _previewFromJpeg;
  final ServerThumbsFn _serverThumbs;
  final FullThumbFn _fullThumb;
  final InstallPackFn _installPack;
  final DiscoverPacksFn _discoverPacks;
  final DateTime Function() _now;

  final int deviceConcurrency;
  final int serverConcurrency;
  final int fullConcurrency;
  final int serverBatchSize;
  final List<Duration> backoff;

  // --- library ---
  List<ThumbRequest> _library = const [];
  final Map<String, int> _libIndex = {};
  final Map<String, String> _assetKeys = {};
  final Map<int, ThumbPackRef> _packsByMessage = {};

  // --- requests from the UI ---
  final LinkedHashSet<String> _prio = LinkedHashSet<String>();
  final LinkedHashSet<String> _fetchKeys = LinkedHashSet<String>();
  final Map<String, ThumbRequest> _reqs = {};
  final Map<String, List<Completer<File?>>> _waiters = {};

  // --- per key state ---
  final Map<String, _KeyState> _state = {};
  final Set<String> _failedKeys = {};

  // --- scheduling ---
  bool _paused = false;
  bool _disposed = false;
  bool _disabled = false;
  bool _booted = false;
  Future<void>? _boot;
  int _devCursor = 0;
  int _srvCursor = 0;
  int _devActive = 0;
  int _devBgActive = 0;
  int _srvActive = 0;
  int _srvBgActive = 0;
  int _fullActive = 0;
  bool _pumping = false;
  bool _repump = false;
  Timer? _wake;
  bool _wasSettled = false;

  // --- packs ---
  final Map<String, String> _applied = {};
  final Set<int> _badPacks = {};
  final Map<int, _Backoff> _packBackoff = {};
  bool _packActive = false;
  bool _discoveryStarted = false;
  bool _discoveryDone = false;

  final ValueNotifier<PrefetchStatus> _status =
      ValueNotifier<PrefetchStatus>(const PrefetchStatus());

  ValueListenable<PrefetchStatus> get status => _status;

  // ------------------------------------------------------------------ API

  /// Replaces the library: every key the app can show, in feed order (newest
  /// first), plus the packs the index knows about.
  void updateLibrary({
    required List<ThumbRequest> inFeedOrder,
    required List<ThumbPackRef> packs,
  }) {
    if (_disposed) return;
    _library = inFeedOrder;
    _libIndex.clear();
    _assetKeys.clear();
    for (var i = 0; i < inFeedOrder.length; i++) {
      final r = inFeedOrder[i];
      _libIndex[r.key] = i;
      final a = r.assetId;
      if (a != null) _assetKeys[a] = r.key;
    }
    for (final pack in packs) {
      _packsByMessage[pack.messageId] = pack;
    }
    _rewind();
    _ensureBooted();
    _pump();
  }

  /// The tile for [r] is on or near the screen: fetch it before anything else.
  /// The most recently prioritized key goes first.
  void prioritize(ThumbRequest r) {
    if (_disposed || _disabled) return;
    if (_store.has(r.key)) return;
    _reqs[r.key] = r;
    final a = r.assetId;
    if (a != null) _assetKeys[a] = r.key;
    _prio
      ..remove(r.key)
      ..add(r.key);
    _ensureBooted();
    _pump();
  }

  /// The tile left the screen. Work already running still completes (its
  /// result is kept); work not started yet is dropped from the priority list.
  void deprioritize(String key) {
    if (_prio.remove(key)) _rewindTo(key);
    _forgetRequest(key);
  }

  /// Like [deprioritize], and also fails any [fetch] still waiting for [id]
  /// (a key, or a device asset id) with null.
  void cancel(String id) {
    final keys = <String>{id};
    for (final k in [..._prio, ..._fetchKeys]) {
      if (_reqs[k]?.assetId == id) keys.add(k);
    }
    for (final k in keys) {
      if (_prio.remove(k)) _rewindTo(k);
      _fetchKeys.remove(k);
      _completeWaiters(k, null);
      _forgetRequest(k);
    }
  }

  /// Prioritizes [r] and completes with its file once it exists, or with null
  /// when it cannot be produced right now (failure, no source, cancelled).
  /// Null is never remembered: asking again tries again (subject to backoff).
  Future<File?> fetch(ThumbRequest r) {
    if (_disposed || _disabled) return Future.value(null);
    final hit = _store.fileIfPresent(r.key);
    if (hit != null) return Future.value(hit);
    final c = Completer<File?>();
    (_waiters[r.key] ??= []).add(c);
    _reqs[r.key] = r;
    final a = r.assetId;
    if (a != null) _assetKeys[a] = r.key;
    _fetchKeys.add(r.key);
    _ensureBooted();
    _pump();
    return c.future;
  }

  /// Stops starting background work (prioritized work continues). Called while
  /// a list is flinging or the app is in the background.
  void pause() {
    if (_paused) return;
    _paused = true;
    _updateStatus();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _pump();
  }

  /// Forgets every backoff and failure so everything is retried now
  /// (pull-to-refresh). Keys marked `noSource` stay so.
  void retryFailedNow() {
    for (final key in _failedKeys) {
      final st = _state[key];
      if (st != null) st.retryAt = null;
    }
    _failedKeys.clear();
    _packBackoff.clear();
    if (_discoveryDone) {
      _discoveryStarted = false;
      _discoveryDone = false;
    }
    _rewind();
    _pump();
  }

  /// The ThumbStore key a request for device asset [assetId] was last made
  /// under (library or prioritized), if any. Lets the viewer find the grid
  /// thumbnail of an asset.
  String? keyForAsset(String assetId) => _assetKeys[assetId];

  /// Cancels timers and drops every waiter (tests).
  @visibleForTesting
  void dispose() {
    _disposed = true;
    _wake?.cancel();
    _wake = null;
    for (final key in _waiters.keys.toList()) {
      _completeWaiters(key, null);
    }
  }

  /// Packs recorded as installed, `message_id -> pack_id` (tests).
  @visibleForTesting
  Map<String, String> get appliedPacksForTesting => Map.unmodifiable(_applied);

  // ------------------------------------------------------------ internals

  _KeyState _st(String key) => _state[key] ??= _KeyState();

  /// The library's request wins (it knows the cloud item AND the asset), then
  /// whatever a tile or [fetch] passed in.
  ThumbRequest? _req(String key) {
    final i = _libIndex[key];
    if (i != null) return _library[i];
    return _reqs[key];
  }

  bool _isRequested(String key) => _prio.contains(key) || _fetchKeys.contains(key);

  void _forgetRequest(String key) {
    if (!_isRequested(key)) _reqs.remove(key);
  }

  void _rewind() {
    _devCursor = 0;
    _srvCursor = 0;
  }

  void _rewindTo(String key) {
    final i = _libIndex[key];
    if (i == null) return;
    _devCursor = math.min(_devCursor, i);
    _srvCursor = math.min(_srvCursor, i);
  }

  void _ensureBooted() {
    _boot ??= _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _store.init();
    } catch (_) {
      // No usable storage (widget tests, no path_provider): stay inert.
      _disabled = true;
      for (final key in _waiters.keys.toList()) {
        _completeWaiters(key, null);
      }
      _prio.clear();
      _fetchKeys.clear();
      _reqs.clear();
      _updateStatus();
      return;
    }
    unawaited(_previews.init());
    await _loadApplied();
    _booted = true;
    _pump();
  }

  void _pump() {
    if (_disposed || _disabled || !_booted) return;
    if (_pumping) {
      _repump = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _repump = false;
        _pumpOnce();
      } while (_repump);
    } finally {
      _pumping = false;
    }
    _scheduleWake();
    _updateStatus();
  }

  void _pumpOnce() {
    _startPackWork();

    final settled = _packsSettled;
    if (settled && !_wasSettled) _rewind(); // background stage 3 may begin
    _wasSettled = settled;

    // Explicit requests (fetch) first, then tiles, most recent first.
    final requested = [..._prio, ..._fetchKeys.where((k) => !_prio.contains(k))];
    final prioBatch = <ThumbRequest>[];
    for (var i = requested.length - 1; i >= 0; i--) {
      final key = requested[i];
      final r = _req(key);
      if (r == null) continue;
      switch (_stageFor(r, prioritized: true)) {
        case _Stage.done:
          _ready(key);
        case _Stage.none:
          _dropRequest(key);
        case _Stage.backoff:
          // Waiters get null now (never "cached"); a tile's priority stays and
          // the wake timer retries it.
          _completeWaiters(key, null);
          _fetchKeys.remove(key);
        case _Stage.device:
          if (_devActive < deviceConcurrency) _startDevice(r, background: false);
        case _Stage.server:
          if (prioBatch.length < serverBatchSize) prioBatch.add(r);
        case _Stage.full:
          if (settled && _fullActive < fullConcurrency) _startFull(r);
        case _Stage.busy:
        case _Stage.waitPacks:
          break;
      }
    }

    // Server thumbnails: prioritized keys, topped up with the library.
    if (_srvActive < serverConcurrency) {
      final canBackground = !_paused && settled;
      final onlyBackground = prioBatch.isEmpty;
      if (!(onlyBackground && (!canBackground || _srvBgActive > 0))) {
        final batch = [...prioBatch];
        if (canBackground) {
          while (batch.length < serverBatchSize && _srvCursor < _library.length) {
            final r = _library[_srvCursor++];
            if (_isRequested(r.key)) continue;
            if (_stageFor(r, prioritized: false) == _Stage.server) batch.add(r);
          }
        }
        if (batch.isNotEmpty) _startServer(batch, background: onlyBackground);
      }
    }

    // Device thumbnails for the whole library, one at a time, while idle.
    while (!_paused && _devBgActive == 0 && _devActive < deviceConcurrency) {
      ThumbRequest? pick;
      while (_devCursor < _library.length) {
        final r = _library[_devCursor++];
        if (_isRequested(r.key)) continue;
        if (_stageFor(r, prioritized: false) == _Stage.device) {
          pick = r;
          break;
        }
      }
      if (pick == null) break;
      _startDevice(pick, background: true);
    }
  }

  /// What [r] needs next. May mark the key `noSource` when nothing can ever
  /// produce it.
  _Stage _stageFor(ThumbRequest r, {required bool prioritized}) {
    final key = r.key;
    if (_store.has(key)) return _Stage.done;
    final st = _state[key];
    if (st != null) {
      if (st.inFlight) return _Stage.busy;
      if (st.noSource) return _Stage.none;
      final at = st.retryAt;
      if (at != null && _now().isBefore(at)) return _Stage.backoff;
    }
    if (r.assetId != null && !(st?.deviceMissing ?? false)) return _Stage.device;
    final file = r.file;
    if (file == null || file.parts.isEmpty) {
      _st(key).noSource = true;
      return _Stage.none;
    }
    final isImage = file.mimeType.startsWith('image/');
    final isVideo = file.mimeType.startsWith('video/');
    if (!isImage && !isVideo) {
      _st(key).noSource = true;
      return _Stage.none;
    }
    if (!(st?.noServerThumb ?? false)) {
      if (!prioritized && !_packsSettled) return _Stage.waitPacks;
      return _Stage.server;
    }
    if (isImage) return _Stage.full;
    _st(key).noSource = true;
    return _Stage.none;
  }

  // --------------------------------------------------------------- stage 1

  void _startDevice(ThumbRequest r, {required bool background}) {
    final st = _st(r.key)..inFlight = true;
    _devActive++;
    if (background) _devBgActive++;
    unawaited(() async {
      try {
        final bytes = await _deviceThumb(r);
        if (bytes == null) {
          // The asset is gone (or has no thumbnail): fall through to the cloud
          // copy if there is one.
          st.deviceMissing = true;
          _rewindTo(r.key);
        } else if (await _store.put(r.key, bytes)) {
          await _storePreview(r.key, bytes);
          _ready(r.key);
        } else {
          _fail(r.key);
        }
      } catch (_) {
        _fail(r.key);
      } finally {
        st.inFlight = false;
        _devActive--;
        if (background) _devBgActive--;
        _pump();
      }
    }());
  }

  // --------------------------------------------------------------- stage 3

  void _startServer(List<ThumbRequest> batch, {required bool background}) {
    _srvActive++;
    if (background) _srvBgActive++;
    for (final r in batch) {
      _st(r.key).inFlight = true;
    }
    unawaited(() async {
      List<ServerThumbResult> results = const [];
      try {
        results = await _serverThumbs([
          for (final r in batch)
            ServerThumbTarget(r.key, _firstMessageId(r.file!), priority: _isRequested(r.key)),
        ]);
      } catch (_) {
        // every key below fails with backoff
      }
      final byKey = {for (final res in results) res.key: res};
      for (final r in batch) {
        final st = _st(r.key);
        try {
          final res = byKey[r.key];
          if (res == null || res.status == ServerThumbResult.statusError) {
            _fail(r.key);
          } else if (res.status == ServerThumbResult.statusNone) {
            st.noServerThumb = true;
          } else {
            final bytes = res.bytes;
            if (bytes != null && await _store.put(r.key, bytes)) {
              await _storePreview(r.key, bytes);
              _ready(r.key);
            } else {
              _fail(r.key);
            }
          }
        } catch (_) {
          _fail(r.key);
        } finally {
          st.inFlight = false;
        }
      }
      _srvActive--;
      if (background) _srvBgActive--;
      _pump();
    }());
  }

  static int _firstMessageId(FileItem file) {
    var best = file.parts.first;
    for (final part in file.parts) {
      if (part.part < best.part) best = part;
    }
    return best.messageId;
  }

  // --------------------------------------------------------------- stage 4

  void _startFull(ThumbRequest r) {
    final st = _st(r.key)..inFlight = true;
    _fullActive++;
    unawaited(() async {
      try {
        final bytes = await _fullThumb(r.file!);
        if (bytes == null) {
          _markNoSource(r.key);
        } else if (await _store.put(r.key, bytes)) {
          await _storePreview(r.key, bytes);
          _ready(r.key);
        } else {
          _fail(r.key);
        }
      } catch (_) {
        _fail(r.key);
      } finally {
        st.inFlight = false;
        _fullActive--;
        _pump();
      }
    }());
  }

  // ----------------------------------------------------------------- packs

  /// Discovery finished and no pack is running or startable right now. Stage 4
  /// and background stage 3 wait for this so a pack does not get pre-empted by
  /// downloads it would have covered.
  bool get _packsSettled =>
      _booted && _discoveryDone && !_packActive && _nextPack() == null;

  ThumbPackRef? _nextPack() {
    final candidates = _packsByMessage.values.where((pack) {
      if (_badPacks.contains(pack.messageId)) return false;
      if (_applied['${pack.messageId}'] == pack.id) return false;
      final b = _packBackoff[pack.messageId];
      return b == null || !_now().isBefore(b.retryAt);
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return candidates.isEmpty ? null : candidates.first;
  }

  void _startPackWork() {
    if (!_discoveryStarted) {
      _discoveryStarted = true;
      unawaited(_runDiscovery());
    }
    if (_packActive) return;
    final pack = _nextPack();
    if (pack == null) return;
    _packActive = true;
    unawaited(_runPack(pack));
  }

  Future<void> _runDiscovery() async {
    try {
      final found = await _discoverPacks();
      for (final pack in found) {
        _packsByMessage.putIfAbsent(pack.messageId, () => pack);
      }
    } catch (_) {
      // Offline: try again at the next retryFailedNow / session.
    } finally {
      _discoveryDone = true;
      _pump();
    }
  }

  Future<void> _runPack(ThumbPackRef pack) async {
    try {
      final dir = await _store.dirPath();
      final res = await _installPack(PackInstallArgs(
        messageId: pack.messageId,
        packId: pack.id,
        dirPath: dir,
      ));
      if (!res.ok) {
        if (res.permanent) {
          _badPacks.add(pack.messageId);
        } else {
          _failPack(pack.messageId);
        }
        return;
      }
      final ids = List<String>.from(res.installedIds);
      _store.markPresent(ids);
      final hashes = <String, Uint8List>{};
      res.previews.forEach((id, wire) {
        final h = PreviewCodec.fromWire(wire);
        if (h != null) hashes[id] = h;
      });
      if (hashes.isNotEmpty) _previews.putAll(hashes);
      _applied['${pack.messageId}'] = res.packId.isEmpty ? pack.id : res.packId;
      _packBackoff.remove(pack.messageId);
      await _saveApplied();
      // Keys a pack covered may be waited for or prioritized.
      final installed = ids.toSet();
      for (final key in {..._waiters.keys, ..._prio, ..._fetchKeys}) {
        if (installed.contains(key)) _ready(key);
      }
    } catch (_) {
      _failPack(pack.messageId);
    } finally {
      _packActive = false;
      _pump();
    }
  }

  void _failPack(int messageId) {
    final b = _packBackoff[messageId] ?? _Backoff();
    b.failures++;
    b.retryAt = _now().add(backoff[math.min(b.failures - 1, backoff.length - 1)]);
    _packBackoff[messageId] = b;
  }

  Future<File?> _appliedFile() async => File(p.join(await _store.dirPath(), '_packs_applied.json'));

  Future<void> _loadApplied() async {
    try {
      final file = await _appliedFile();
      if (file == null) return;
      _applied.addAll(await _readAppliedFile(file));
    } catch (_) {
      // Unreadable bookkeeping: packs are simply reinstalled (idempotent).
    }
  }

  /// The `messageId -> packId` map stored in [file] (empty when missing or
  /// unreadable).
  static Future<Map<String, String>> _readAppliedFile(File file) async {
    final out = <String, String>{};
    if (!await file.exists()) return out;
    final doc = jsonDecode(await file.readAsString());
    if (doc is Map && doc['v'] == 1 && doc['packs'] is Map) {
      (doc['packs'] as Map).forEach((k, v) {
        if (k is String && v is String) out[k] = v;
      });
    }
    return out;
  }

  /// The backfill (`backfill_service.dart`) records the packs it produces in
  /// the same file, so this one never writes its own map wholesale: it reads
  /// the file, merges its entries over it, writes through a temp file and
  /// renames, and keeps what the file had (the pack the backfill just made is
  /// then not downloaded again).
  Future<void> _saveApplied() async {
    try {
      final file = await _appliedFile();
      if (file == null) return;
      Map<String, String> onDisk = const {};
      try {
        onDisk = await _readAppliedFile(file);
      } catch (_) {
        // Unreadable: rewritten from memory alone.
      }
      final merged = {...onDisk, ..._applied};
      _applied.addAll(merged);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'packs': merged}), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Not fatal: the next session reinstalls (idempotent).
    }
  }

  /// Another producer (the thumbnail backfill) installed or registered pack
  /// [packId], living in Telegram message [messageId], on this device: do not
  /// download it again. Memory only; the producer already wrote the file.
  void markPackApplied(String packId, int messageId) {
    _applied['$messageId'] = packId;
    _packBackoff.remove(messageId);
  }

  // ------------------------------------------------------ results & upkeep

  Future<void> _storePreview(String key, Uint8List jpeg) async {
    if (_previews.hash(key) != null) return;
    try {
      final hash = await _previewFromJpeg(jpeg);
      if (hash != null) _previews.put(key, hash);
    } catch (_) {
      // A missing preview only costs the placeholder colour.
    }
  }

  void _ready(String key) {
    final st = _state[key];
    if (st != null) {
      st.failures = 0;
      st.retryAt = null;
    }
    _failedKeys.remove(key);
    _prio.remove(key);
    _fetchKeys.remove(key);
    _completeWaiters(key, _store.fileIfPresent(key));
    _forgetRequest(key);
  }

  void _fail(String key) {
    final st = _st(key);
    st.failures++;
    st.retryAt = _now().add(backoff[math.min(st.failures - 1, backoff.length - 1)]);
    _failedKeys.add(key);
    _fetchKeys.remove(key);
    _completeWaiters(key, null);
    _forgetRequest(key);
  }

  void _markNoSource(String key) {
    _st(key).noSource = true;
    _dropRequest(key);
  }

  /// Nothing can produce [key]: stop tracking the request and tell waiters.
  void _dropRequest(String key) {
    _prio.remove(key);
    _fetchKeys.remove(key);
    _completeWaiters(key, null);
    _forgetRequest(key);
  }

  void _completeWaiters(String key, File? file) {
    final list = _waiters.remove(key);
    if (list == null) return;
    for (final c in list) {
      if (!c.isCompleted) c.complete(file);
    }
  }

  void _scheduleWake() {
    DateTime? soonest;
    final now = _now();
    void consider(DateTime? at) {
      if (at == null || !at.isAfter(now)) return;
      if (soonest == null || at.isBefore(soonest!)) soonest = at;
    }

    _failedKeys.removeWhere((key) {
      final at = _state[key]?.retryAt;
      if (at == null || !at.isAfter(now)) return true;
      consider(at);
      return false;
    });
    for (final b in _packBackoff.values) {
      consider(b.retryAt);
    }
    _wake?.cancel();
    _wake = null;
    final at = soonest;
    if (at == null || _disposed) return;
    _wake = Timer(at.difference(now) + const Duration(milliseconds: 2), () {
      _wake = null;
      _rewind();
      _pump();
    });
  }

  void _updateStatus() {
    _status.value = PrefetchStatus(
      queued: {..._prio, ..._fetchKeys}.length,
      active: _devActive + _srvActive + _fullActive + (_packActive ? 1 : 0),
      packsPending: _packsByMessage.values
          .where((pk) =>
              !_badPacks.contains(pk.messageId) &&
              _applied['${pk.messageId}'] != pk.id &&
              !_packBackoff.containsKey(pk.messageId))
          .length,
      failed: _failedKeys.length,
      paused: _paused,
    );
  }
}

enum _Stage { done, busy, backoff, none, waitPacks, device, server, full }

class _KeyState {
  int failures = 0;
  DateTime? retryAt;
  bool inFlight = false;

  /// Nothing can produce this key (until the next session).
  bool noSource = false;

  /// Telegram has no usable server thumbnail for it.
  bool noServerThumb = false;

  /// The device asset is gone; only the cloud copy remains.
  bool deviceMissing = false;
}

class _Backoff {
  int failures = 0;
  DateTime retryAt = DateTime.fromMillisecondsSinceEpoch(0);
}

// ------------------------------------------------------------------ defaults

Future<Uint8List?> _defaultDeviceThumb(ThumbRequest r) async {
  final asset = r.asset ?? await AssetEntity.fromId(r.assetId!);
  if (asset == null) return null;
  return asset.thumbnailDataWithSize(
    const ThumbnailSize(256, 256),
    format: ThumbnailFormat.jpeg,
    quality: 80,
  );
}

/// Decodes [jpeg] to at most ~32 px with the engine's own decoder (main
/// isolate only) and hashes it. Null on any failure.
Future<Uint8List?> defaultPreviewFromJpeg(Uint8List jpeg) async {
  try {
    final codec = await ui.instantiateImageCodec(jpeg, targetWidth: 32);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (raw == null) return null;
        return PreviewCodec.encodeRgba(
          raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
          image.width,
          image.height,
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}

Future<List<ServerThumbResult>> _defaultServerThumbs(List<ServerThumbTarget> targets) async {
  final raw = await DownloadWorker.run<ServerThumbArgs, List<Object?>>(
    fetchServerThumbs,
    ServerThumbArgs(targets),
    inactivityTimeout: const Duration(seconds: 45),
  );
  return raw.whereType<ServerThumbResult>().toList();
}

/// Largest thumbnail JPEG a full download may produce.
const int kMaxFullThumbBytes = 200 * 1024;

Future<Uint8List?> _defaultFullThumb(FileItem file) async {
  if (!file.mimeType.startsWith('image/')) return null;
  final full = await DownloadService.instance.downloadToCache(file);
  final src = await full.readAsBytes();
  final out = await resizeToThumbnail(src);
  // `resizeToThumbnail` hands back the very same bytes when it cannot decode.
  if (identical(out, src) || !looksLikeJpeg(out) || out.length > kMaxFullThumbBytes) {
    return null;
  }
  return out;
}

Future<PackInstallResult> _defaultInstallPack(PackInstallArgs args) =>
    DownloadWorker.run<PackInstallArgs, PackInstallResult>(
      installPack,
      args,
      inactivityTimeout: const Duration(seconds: 60),
    );

Future<List<ThumbPackRef>> _defaultDiscoverPacks() async {
  final raw = await DownloadWorker.run<Object?, List<Object?>>(
    discoverPacks,
    null,
    inactivityTimeout: const Duration(seconds: 30),
  );
  return raw.whereType<ThumbPackRef>().toList();
}
