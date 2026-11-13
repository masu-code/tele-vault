import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tv_core/codecs.dart' show ThumbPackCodec;
import 'package:tv_core/models.dart' show FileItem;
import 'package:uuid/uuid.dart';

import '../download/download_worker.dart';
import 'backfill_service.dart' show WorkerBackfillRemote;
import 'backfill_state.dart';
import 'pack_coverage.dart';
import 'pack_installer.dart';
import 'pack_publisher.dart';
import 'preview_table.dart';
import 'thumb_store.dart';

/// Why an automatic packing run ended the way it did.
enum AutoPackOutcome {
  /// At least one pack was uploaded and recorded.
  packed,

  /// Not enough candidates (or not old enough) for a pack.
  belowThreshold,

  /// A pack's TOC could not be read: nothing is packed this run.
  coverageUnknown,

  /// The index is loading, saving or failed, or the thumbnail folder is
  /// unavailable.
  notReady,

  /// Another run of this service is in progress.
  busy,
}

/// Counts only.
@immutable
class AutoPackResult {
  const AutoPackResult(this.outcome, {this.candidates = 0, this.packs = 0, this.packedThumbs = 0});
  final AutoPackOutcome outcome;
  final int candidates;
  final int packs;
  final int packedThumbs;
}

/// Packs, with no download at all, the cloud thumbnails this device already
/// has in its [ThumbStore] (stored at upload time or fetched by the
/// prefetcher) that no pack covers yet, so a fresh install or another device
/// installs a few packs instead of fetching thousands of single thumbnails.
///
/// Candidates: image/video items of the index with a thumbnail in the store
/// that are not in any pack of `index.thumbPacks` (coverage from
/// [PackCoverage]: TOC reads, cached), nor in a pack, pending pack or
/// pack-waiting list of the backfill job or of this service. A run packs when
/// there are at least [fullThreshold] candidates, or at least
/// [agedThreshold] whose oldest thumbnail is older than [maxAge]; at most
/// [maxPacksPerRun] packs per run.
///
/// Idempotent through its own [BackfillStateStore] (`<appSupport>/auto_pack/`):
/// a pack is recorded as pending before its upload and looked up by caption
/// on resume. Telegram writes: the pack `sendMedia` and the index save
/// through [BackfillIndexAccess.write]. Network gating and the cross-process
/// lock belong to the caller (`AutoMaintenanceService`).
class AutoPackService {
  AutoPackService({
    required BackfillIndexAccess index,
    PackRemote? remote,
    ThumbStore? store,
    PreviewTable? previews,
    BackfillStateStore? stateStore,
    BackfillStateStore? backfillStateStore,
    PackCoverage? coverage,
    Future<PackTocResult> Function(int messageId)? readToc,
    Future<Directory> Function()? workDir,
    Future<DateTime?> Function(String id)? thumbTime,
    DateTime Function()? now,
    String Function()? newPackId,
    void Function(String packId, int messageId)? onPackApplied,
    this.maxPackEntries = ThumbPackCodec.maxEntries,
    this.maxPackDataBytes = kPackDataBytes,
    this.fullThreshold = 256,
    this.agedThreshold = 64,
    this.maxAge = const Duration(hours: 24),
    this.maxPacksPerRun = 2,
  })  : _indexAccess = index,
        _store = store ?? ThumbStore.instance,
        _previews = previews ?? PreviewTable.instance,
        _stateStore = stateStore ?? BackfillStateStore(_defaultStateDir),
        _backfillStateStore =
            backfillStateStore ?? BackfillStateStore(getApplicationSupportDirectory),
        _readToc = readToc ?? _workerReadToc,
        _now = now ?? DateTime.now,
        _newPackId = newPackId ?? const Uuid().v4 {
    final s = _store;
    _coverage = coverage ?? PackCoverage(s);
    _thumbTime = thumbTime ?? _defaultThumbTime;
    _publisher = PackPublisher(
      index: _indexAccess,
      remote: remote ?? const WorkerBackfillRemote(),
      store: s,
      previews: _previews,
      stateStore: _stateStore,
      workDir: workDir ?? _defaultWorkDir,
      coverage: _coverage,
      onPackApplied: onPackApplied,
      log: _log,
    );
  }

  final BackfillIndexAccess _indexAccess;
  final ThumbStore _store;
  final PreviewTable _previews;
  final BackfillStateStore _stateStore;
  final BackfillStateStore _backfillStateStore;
  final Future<PackTocResult> Function(int messageId) _readToc;
  final DateTime Function() _now;
  final String Function() _newPackId;
  late final PackCoverage _coverage;
  late final Future<DateTime?> Function(String id) _thumbTime;
  late final PackPublisher _publisher;

  final int maxPackEntries;
  final int maxPackDataBytes;
  final int fullThreshold;
  final int agedThreshold;
  final Duration maxAge;
  final int maxPacksPerRun;

  bool _busy = false;

  bool get isBusy => _busy;

  /// One packing pass (see the class comment). Never downloads a thumbnail
  /// or an original; the only reads are pack TOCs not cached yet.
  Future<AutoPackResult> run() async {
    if (_busy) return const AutoPackResult(AutoPackOutcome.busy);
    _busy = true;
    try {
      final index = _indexAccess.current();
      if (index == null) return const AutoPackResult(AutoPackOutcome.notReady);
      try {
        await _store.init();
      } catch (_) {
        return const AutoPackResult(AutoPackOutcome.notReady);
      }
      await _previews.init();

      final own = await _stateStore.load();
      var packs = 0;
      var packedThumbs = 0;
      // A pack interrupted by a crash or an error is finished first (found by
      // its caption when it may have reached Telegram: never sent twice).
      if (own.pending != null) {
        final n = own.pending!.ids.length;
        await _publisher.completePending(own);
        packs++;
        packedThumbs += n;
      }

      final bf = await _backfillStateStore.load();
      final known = <int>{
        for (final r in own.packs) r.messageId,
        for (final r in bf.packs) r.messageId,
        if (bf.pending?.messageId != null) bf.pending!.messageId!,
      };
      final current = _indexAccess.current() ?? index;
      final covered = await _coverage.coveredBy(current.thumbPacks, readToc: _readToc, known: known);
      if (covered == null) {
        _log('coverage unknown packs=${current.thumbPacks.length}, nothing packed');
        return AutoPackResult(AutoPackOutcome.coverageUnknown, packs: packs, packedThumbs: packedThumbs);
      }
      final excluded = <String>{
        ...covered,
        ...own.packed,
        ...bf.packed,
        ...bf.produced.keys,
        ...?bf.pending?.ids,
      };
      var candidates = <String>[
        for (final f in current.files)
          if (_isMedia(f) &&
              f.parts.isNotEmpty &&
              ThumbKey.isSafe(f.id) &&
              _store.has(f.id) &&
              !excluded.contains(f.id))
            f.id,
      ];
      final found = candidates.length;
      _log('candidates=$found covered=${covered.length} indexPacks=${current.thumbPacks.length}');

      while (packs < maxPacksPerRun && await _due(candidates)) {
        final ids = await _pick(candidates);
        if (ids.isEmpty) break;
        own.pending = PendingPack(packId: _newPackId(), createdAt: _now().toUtc(), ids: ids);
        await _stateStore.save(own);
        final taken = ids.toSet();
        await _publisher.completePending(own);
        packs++;
        packedThumbs += ids.length;
        candidates = [for (final id in candidates) if (!taken.contains(id)) id];
      }
      _log('run packs=$packs thumbs=$packedThumbs left=${candidates.length}');
      return AutoPackResult(
        packs > 0 ? AutoPackOutcome.packed : AutoPackOutcome.belowThreshold,
        candidates: found,
        packs: packs,
        packedThumbs: packedThumbs,
      );
    } finally {
      _busy = false;
    }
  }

  /// The trigger rule: enough candidates, or enough old ones.
  Future<bool> _due(List<String> candidates) async {
    if (candidates.length >= fullThreshold) return true;
    if (candidates.length < agedThreshold) return false;
    final limit = _now().subtract(maxAge);
    for (final id in candidates) {
      final t = await _thumbTime(id);
      if (t != null && t.isBefore(limit)) return true;
    }
    return false;
  }

  /// The next pack's ids in index order: at most [maxPackEntries] and
  /// [maxPackDataBytes] of JPEG data.
  Future<List<String>> _pick(List<String> candidates) async {
    final ids = <String>[];
    var bytes = 0;
    for (final id in candidates) {
      if (ids.length >= maxPackEntries) break;
      final size = await _thumbSize(id);
      if (size == null || size <= 0 || size > ThumbPackCodec.maxBlobBytes) continue;
      if (bytes + size > maxPackDataBytes) break;
      ids.add(id);
      bytes += size;
    }
    return ids;
  }

  Future<int?> _thumbSize(String id) async {
    try {
      return await _store.fileIfPresent(id)?.length();
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> _defaultThumbTime(String id) async {
    try {
      final f = _store.fileIfPresent(id);
      if (f == null) return null;
      final st = await f.stat();
      return st.type == FileSystemEntityType.notFound ? null : st.modified;
    } catch (_) {
      return null;
    }
  }

  static bool _isMedia(FileItem f) =>
      f.mimeType.startsWith('image/') || f.mimeType.startsWith('video/');

  static void _log(String message) => debugPrint('TVDIAG: autopack $message');

  static Future<Directory> _defaultStateDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'auto_pack'));
  }

  static Future<Directory> _defaultWorkDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'televault_autopack'));
  }

  static Future<PackTocResult> _workerReadToc(int messageId) =>
      DownloadWorker.run<int, PackTocResult>(
        readPackToc,
        messageId,
        inactivityTimeout: const Duration(seconds: 60),
      );
}
