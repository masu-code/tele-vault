import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pool/pool.dart';
import 'package:t/t.dart' as t;
import 'package:tv_core/codecs.dart';
import 'package:tv_core/models.dart' show FileIndex, FileItem, ThumbPackRef;
import 'package:uuid/uuid.dart';

import '../download/download_service.dart';
import '../download/download_worker.dart';
import '../telegram/client.dart';
import '../telegram/tg_utils.dart';
import '../upload/upload_plan.dart' show UploadLimits;
import 'backfill_state.dart';
import 'pack_installer.dart';
import 'preview_table.dart';
import 'server_thumb_batch.dart';
import 'thumb_encoder.dart';
import 'thumb_prefetcher.dart' show ThumbPrefetcher, defaultPreviewFromJpeg;
import 'thumb_store.dart';

/// Data bytes per pack the job aims for (the format allows 8 MiB).
const int kBackfillPackDataBytes = 7 * 1024 * 1024 + 512 * 1024;

/// Longest side of a thumbnail the job makes from an original.
const int kBackfillThumbSide = 320;

/// Something stopped the job before it did any work (no unmetered network,
/// index not loaded, already running). Safe to show: no names or paths.
class BackfillBlockedException implements Exception {
  const BackfillBlockedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The job failed part-way; its state file lets the next run resume.
class BackfillException implements Exception {
  const BackfillException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ------------------------------------------------------------------- seams

/// The app's index as the job sees it.
abstract class BackfillIndexAccess {
  /// The index as currently loaded and saved, or null when it is loading,
  /// saving, stale or failed (the job then does nothing to it).
  FileIndex? current();

  /// Applies [mutate] to the freshest index, saves it through
  /// `IndexService.save` and returns the index that was actually written.
  /// When [mutate] returns its argument unchanged (identical), nothing is
  /// written and that index is returned.
  Future<FileIndex> write(FileIndex Function(FileIndex current) mutate);
}

/// What the job learns about a candidate's first Telegram message without
/// downloading anything.
class BackfillProbe {
  const BackfillProbe(this.messageId, {required this.exists, required this.hasServerThumb});
  final int messageId;

  /// The message is there and holds a document.
  final bool exists;

  /// Telegram has a usable embedded thumbnail (<= 320 px) for it.
  final bool hasServerThumb;
}

/// A local copy of an original. Only an [owned] copy (downloaded by the job
/// into its work directory) is ever deleted; a device original or the
/// viewer's cache file is read and left alone.
class BackfillOriginal {
  const BackfillOriginal(this.file, {required this.owned});
  final File file;
  final bool owned;
}

/// Telegram access used by the job. The only writes are [uploadPack]
/// (`saveFilePart` + `sendMedia` of a pack document); the index is written
/// through [BackfillIndexAccess].
abstract class BackfillRemote {
  Future<List<BackfillProbe>> probe(List<int> messageIds);
  Future<List<ServerThumbResult>> serverThumbs(List<ServerThumbTarget> targets);

  /// Downloads (or finds locally) [item]'s original. [workDir] is the item's
  /// own scratch directory.
  Future<BackfillOriginal> fetchOriginal(FileItem item, String workDir);

  /// Sends the pack file at [path] as a document captioned
  /// `TELEVAULT_THUMBS_V1 <packId>`; returns its message id.
  Future<int> uploadPack(String path, String packId);

  /// The pack message with caption id [packId], if one is in Saved Messages.
  Future<ThumbPackRef?> findPack(String packId);

  Future<PackInstallResult> installPack(PackInstallArgs args);
}

/// A thumbnail made by the job: JPEG, its size, and its ThumbHash (if any).
class EncodedThumb {
  const EncodedThumb(this.jpeg, this.width, this.height, this.preview);
  final Uint8List jpeg;
  final int width;
  final int height;
  final Uint8List? preview;
}

/// Turns originals and server thumbnails into thumbnails + previews.
abstract class BackfillCodec {
  /// The Flutter engine can probably decode this image type.
  bool engineCanDecode(String mime);

  /// `ffmpeg` is on PATH (Windows only).
  Future<bool> ffmpegAvailable();

  Future<EncodedThumb?> encodeImage(File file);
  Future<EncodedThumb?> encodeWithFfmpeg(File file, String workDir);
  Future<Uint8List?> previewOf(Uint8List jpeg);
}

// ---------------------------------------------------------------- service

enum _Route { server, download, desktop, missing }

/// Backfill of thumbnails + previews for cloud items that have neither a
/// thumbnail on this device nor a pack entry, followed by thumbnail packs
/// (TVTP, one Telegram document per <= 512 thumbnails) recorded in the index
/// so every other device installs them instead of downloading originals.
///
/// Per candidate: Telegram's server thumbnail when it has one; otherwise the
/// original is downloaded into a work directory, decoded by the engine at
/// <= 320 px (or by `ffmpeg` on Windows for videos and formats the engine
/// cannot decode) and deleted right after. Items that only a desktop with
/// ffmpeg can handle are counted as `needsDesktop`.
///
/// Resumable at any point: `backfill_state.json` + a journal of produced
/// thumbnails; a pack is recorded as pending before its upload and looked up
/// by caption on resume, so a crash never yields a second pack with the same
/// thumbnails. Every index write goes through [BackfillIndexAccess.write]
/// (backup, conditional write, rebase and read-back come from IndexService).
class BackfillService {
  BackfillService({
    required BackfillIndexAccess index,
    BackfillRemote? remote,
    BackfillCodec? codec,
    ThumbStore? store,
    PreviewTable? previews,
    BackfillStateStore? stateStore,
    Future<Directory> Function()? workDir,
    Future<bool> Function()? networkAllowed,
    bool? requireUnmetered,
    this.downloadConcurrency = 3,
    this.serverBatchSize = 50,
    this.probeBatchSize = 500,
    this.maxPackEntries = ThumbPackCodec.maxEntries,
    this.maxPackDataBytes = kBackfillPackDataBytes,
    this.maxAttempts = 3,
    DateTime Function()? now,
    String Function()? newPackId,
    this.onPackApplied,
  })  : _indexAccess = index,
        _remote = remote ?? const WorkerBackfillRemote(),
        _codec = codec ?? EngineBackfillCodec(),
        _store = store ?? ThumbStore.instance,
        _previews = previews ?? PreviewTable.instance,
        _stateStore = stateStore ?? BackfillStateStore(getApplicationSupportDirectory),
        _workDir = workDir ?? _defaultWorkDir,
        _networkAllowed = networkAllowed ?? _unmeteredNetwork,
        _requireUnmetered = requireUnmetered ?? Platform.isAndroid,
        _now = now ?? DateTime.now,
        _newPackId = newPackId ?? const Uuid().v4;

  final BackfillIndexAccess _indexAccess;
  final BackfillRemote _remote;
  final BackfillCodec _codec;
  final ThumbStore _store;
  final PreviewTable _previews;
  final BackfillStateStore _stateStore;
  final Future<Directory> Function() _workDir;
  final Future<bool> Function() _networkAllowed;
  final bool _requireUnmetered;
  final DateTime Function() _now;
  final String Function() _newPackId;

  /// Tells the prefetcher a pack is applied on this device, so it does not
  /// download one the backfill just produced or installed. Defaults to
  /// [ThumbPrefetcher.markPackApplied] on its singleton.
  final void Function(String packId, int messageId)? onPackApplied;

  final int downloadConcurrency;
  final int serverBatchSize;
  final int probeBatchSize;
  final int maxPackEntries;
  final int maxPackDataBytes;

  /// A candidate that failed this many runs is left out (and reported).
  final int maxAttempts;

  final ValueNotifier<BackfillProgress> _progress =
      ValueNotifier<BackfillProgress>(const BackfillProgress());

  ValueListenable<BackfillProgress> get progress => _progress;

  /// Whether Run must check for an unmetered network first (Android).
  bool get requiresUnmeteredNetwork => _requireUnmetered;

  bool _busy = false;
  bool _pauseRequested = false;
  Object? _abort;
  Future<void> _packChain = Future<void>.value();

  /// Ids whose thumbnail is being written right now (not packable yet).
  final Set<String> _producing = <String>{};

  bool get isBusy => _busy;

  /// Stops starting new items; work in flight finishes and is kept. The
  /// state stays resumable: the next [run] continues where this one stopped.
  void pause() {
    if (_busy) _pauseRequested = true;
  }

  // ---------------------------------------------------------------- plan

  /// Counts and bytes a run would download. Reads the index and asks
  /// Telegram for message metadata only: nothing is downloaded or written.
  Future<BackfillPlan> plan() async {
    if (_busy) throw const BackfillBlockedException('The backfill job is already running.');
    _busy = true;
    _set(const BackfillProgress(phase: BackfillPhase.planning));
    try {
      final index = _usableIndex();
      await _initStores();
      final state = await _stateStore.load();
      final applied = await _readApplied();
      final toInstall = [
        for (final r in index.thumbPacks)
          if (applied['${r.messageId}'] != r.id && !_isOwnPack(state, r)) r,
      ];
      final ffmpeg = await _codec.ffmpegAvailable();
      final scan = _scan(index, state, ffmpeg: ffmpeg);
      final probes = await _probeAll(scan.candidates);

      var server = 0, images = 0, videos = 0, desktop = 0, missing = 0, bytes = 0;
      final byMime = <String, int>{};
      for (final f in scan.candidates) {
        byMime[f.mimeType] = (byMime[f.mimeType] ?? 0) + 1;
        switch (_route(f, probes[_firstMessageId(f)], ffmpeg)) {
          case _Route.server:
            server++;
          case _Route.download:
            if (_isVideo(f)) {
              videos++;
            } else {
              images++;
            }
            bytes += f.totalSize;
          case _Route.desktop:
            desktop++;
          case _Route.missing:
            missing++;
        }
      }
      final plan = BackfillPlan(
        mediaTotal: scan.mediaTotal,
        candidates: scan.candidates.length,
        serverThumbs: server,
        imagesToDownload: images,
        videosToDownload: videos,
        needsDesktop: desktop + scan.desktopSkipped,
        missing: missing,
        bytesToDownload: bytes,
        awaitingPack: state.produced.length + (state.pending?.ids.length ?? 0),
        packed: state.packed.length,
        skippedFailures: scan.failedSkipped,
        packsToInstall: toInstall.length,
        packBytesToInstall: toInstall.fold<int>(0, (s, r) => s + r.size),
        previewPatches: _previewPatches(index, state.packed).length,
        candidatesByMime: byMime,
      );
      _log('plan media=${plan.mediaTotal} candidates=${plan.candidates} server=$server '
          'images=$images videos=$videos desktop=${plan.needsDesktop} missing=$missing '
          'bytes=$bytes packsToInstall=${toInstall.length}');
      _set(const BackfillProgress());
      return plan;
    } catch (e) {
      _set(BackfillProgress(phase: BackfillPhase.failed, error: _safeMessage(e)));
      rethrow;
    } finally {
      _busy = false;
    }
  }

  // ----------------------------------------------------------------- run

  Future<BackfillRunResult> run() async {
    if (_busy) throw const BackfillBlockedException('The backfill job is already running.');
    _busy = true;
    _pauseRequested = false;
    _abort = null;
    BackfillState? state;
    try {
      if (_requireUnmetered && !await _networkAllowed()) {
        throw const BackfillBlockedException(
            'The backfill job needs Wi-Fi or Ethernet (an unmetered network).');
      }
      final index = _usableIndex();
      _set(const BackfillProgress(phase: BackfillPhase.preparing));
      await _initStores();
      final s = state = await _stateStore.load();
      await _cleanWorkDir();

      // A pack interrupted by a crash or an error is finished first.
      if (s.pending != null) await _completePending(s);
      final covered = await _installIndexPacks(index, s);

      final ffmpeg = await _codec.ffmpegAvailable();
      final scan = _scan(_indexAccess.current() ?? index, s, ffmpeg: ffmpeg);
      final candidates = scan.candidates;
      _set(_progress.value.copyWith(
        phase: BackfillPhase.serverThumbs,
        total: candidates.length,
        needsDesktop: s.needsDesktop.length,
        bytesDownloaded: s.bytesDownloaded,
      ));

      final probes = await _probeAll(candidates);
      final serverList = <FileItem>[];
      final downloadList = <FileItem>[];
      for (final f in candidates) {
        switch (_route(f, probes[_firstMessageId(f)], ffmpeg)) {
          case _Route.server:
            serverList.add(f);
          case _Route.download:
            downloadList.add(f);
          case _Route.desktop:
            _needsDesktop(s, f);
          case _Route.missing:
            _fail(s, f, 'missing');
        }
      }
      _log('run candidates=${candidates.length} server=${serverList.length} '
          'download=${downloadList.length} ffmpeg=$ffmpeg');

      await _serverPhase(s, serverList, downloadList, ffmpeg);
      _throwIfAborted();

      _set(_progress.value.copyWith(phase: BackfillPhase.downloading));
      final pool = Pool(downloadConcurrency);
      try {
        await Future.wait([
          for (final f in downloadList)
            pool.withResource(() async {
              if (_pauseRequested || _abort != null) return;
              await _downloadOne(s, f, ffmpeg);
            }),
        ]);
      } finally {
        await pool.close();
      }
      await _packChain;
      _throwIfAborted();

      final paused = _pauseRequested;
      var patched = 0;
      if (!paused) {
        _set(_progress.value.copyWith(phase: BackfillPhase.packing));
        await _flush(s, all: true);
        _throwIfAborted();
        _set(_progress.value.copyWith(phase: BackfillPhase.patching));
        patched = await _patch(s, covered);
      }
      s.lastRunAt = _now().toUtc();
      s.lastResult = paused ? 'paused' : 'done';
      await _stateStore.save(s);
      final result = BackfillRunResult(
        produced: _progress.value.produced,
        packsUploaded: _progress.value.packsUploaded,
        previewsPatched: patched,
        needsDesktop: s.needsDesktop.length,
        failures: Map.unmodifiable(s.failed),
        paused: paused,
      );
      _log('run ${s.lastResult} produced=${result.produced} packs=${result.packsUploaded} '
          'patched=$patched desktop=${result.needsDesktop} failed=${s.failed.length}');
      _set(_progress.value.copyWith(
        phase: paused ? BackfillPhase.paused : BackfillPhase.done,
        failures: s.failed.length,
        needsDesktop: s.needsDesktop.length,
      ));
      return result;
    } catch (e) {
      await _packChain.catchError((Object _) {});
      final s = state;
      if (s != null) {
        s.lastRunAt = _now().toUtc();
        s.lastResult = 'failed';
        try {
          await _stateStore.save(s);
        } catch (_) {}
      }
      _log('run failed: ${e.runtimeType}');
      _set(_progress.value.copyWith(phase: BackfillPhase.failed, error: _safeMessage(e)));
      rethrow;
    } finally {
      _busy = false;
      _pauseRequested = false;
    }
  }

  // ------------------------------------------------------------- phases

  Future<void> _serverPhase(
    BackfillState s,
    List<FileItem> serverList,
    List<FileItem> downloadList,
    bool ffmpeg,
  ) async {
    for (var i = 0; i < serverList.length; i += serverBatchSize) {
      if (_pauseRequested || _abort != null) return;
      final batch = serverList.sublist(i, math.min(i + serverBatchSize, serverList.length));
      List<ServerThumbResult> results = const [];
      try {
        results = await _remote.serverThumbs([
          for (final f in batch) ServerThumbTarget(f.id, _firstMessageId(f)),
        ]);
      } catch (_) {
        // every item below counts as a retryable failure
      }
      final byKey = {for (final r in results) r.key: r};
      for (final f in batch) {
        final r = byKey[f.id];
        final bytes = r?.bytes;
        if (r != null && r.status == ServerThumbResult.statusOk && bytes != null) {
          final size = jpegSize(bytes);
          if (size == null) {
            _fail(s, f, 'server-invalid');
            continue;
          }
          final preview = await _safePreview(bytes);
          await _accept(s, f, EncodedThumb(bytes, size.w, size.h, preview));
        } else if (r != null && r.status == ServerThumbResult.statusNone) {
          // Telegram has no usable thumbnail after all: same as no thumb.
          final route = _routeNoServer(f, ffmpeg);
          if (route == _Route.download) {
            downloadList.add(f);
          } else {
            _needsDesktop(s, f);
          }
        } else {
          _fail(s, f, 'server');
        }
      }
    }
  }

  Future<void> _downloadOne(BackfillState s, FileItem f, bool ffmpeg) async {
    if (!ThumbKey.isSafe(f.id)) {
      _fail(s, f, 'id');
      return;
    }
    final itemDir = p.join((await _workDir()).path, f.id);
    BackfillOriginal? original;
    EncodedThumb? thumb;
    Object? error;
    try {
      original = await _remote.fetchOriginal(f, itemDir);
      if (original.owned) {
        s.bytesDownloaded += f.totalSize;
        _set(_progress.value.copyWith(bytesDownloaded: s.bytesDownloaded));
      }
      if (!_isVideo(f) && _codec.engineCanDecode(f.mimeType)) {
        thumb = await _codec.encodeImage(original.file);
      }
      if (thumb == null && ffmpeg) {
        thumb = await _codec.encodeWithFfmpeg(original.file, itemDir);
      }
    } catch (e) {
      error = e;
    } finally {
      // The original goes right after encoding, whatever happened.
      await _discard(original, itemDir);
    }
    if (error != null) {
      _fail(s, f, 'download:${error.runtimeType}');
      return;
    }
    if (thumb == null) {
      if (ffmpeg) {
        _fail(s, f, 'undecodable');
      } else {
        _needsDesktop(s, f);
      }
      return;
    }
    await _accept(s, f, thumb);
  }

  /// Stores a made thumbnail and its preview and queues it for a pack.
  Future<void> _accept(BackfillState s, FileItem f, EncodedThumb thumb) async {
    final jpeg = thumb.jpeg;
    if (!looksLikeJpeg(jpeg) || jpeg.length > ThumbPackCodec.maxBlobBytes) {
      _fail(s, f, 'oversize');
      return;
    }
    // Journal first: a crash after this but before the store write leaves an
    // id without a file, which the pack builder drops (the item is then a
    // candidate again); the other order could leave a thumbnail no pack
    // ever gets.
    _producing.add(f.id);
    s.produced[f.id] = jpeg.length;
    var ok = false;
    try {
      await _stateStore.appendProduced(f.id, jpeg.length);
      ok = await _store.put(f.id, jpeg);
    } catch (_) {
      ok = false;
    } finally {
      _producing.remove(f.id);
    }
    if (!ok) {
      s.produced.remove(f.id);
      _fail(s, f, 'store');
      return;
    }
    final hash = thumb.preview;
    if (hash != null && _previews.hash(f.id) == null) _previews.put(f.id, hash);
    s.failed.remove(f.id);
    s.needsDesktop.remove(f.id);
    _set(_progress.value.copyWith(
      produced: _progress.value.produced + 1,
      processed: _progress.value.processed + 1,
    ));
    if (_pickForPack(s, all: false) != null) _kickFlush(s);
  }

  // --------------------------------------------------------------- packs

  void _kickFlush(BackfillState s) {
    _packChain = _packChain.then((_) async {
      if (_abort != null) return;
      try {
        await _flushNow(s, all: false);
      } catch (e) {
        _abort ??= e;
      }
    });
  }

  Future<void> _flush(BackfillState s, {required bool all}) {
    final f = _packChain.then((_) => _flushNow(s, all: all));
    _packChain = f.catchError((Object _) {});
    return f;
  }

  Future<void> _flushNow(BackfillState s, {required bool all}) async {
    while (true) {
      if (s.pending != null) await _completePending(s);
      final ids = _pickForPack(s, all: all);
      if (ids == null) return;
      s.pending = PendingPack(packId: _newPackId(), createdAt: _now().toUtc(), ids: ids);
      for (final id in ids) {
        s.produced.remove(id);
      }
      await _stateStore.save(s);
      await _completePending(s);
    }
  }

  /// The next pack's ids in production order, or null when there is nothing
  /// to pack (or, unless [all], not a full pack yet).
  List<String>? _pickForPack(BackfillState s, {required bool all}) {
    final ids = <String>[];
    var bytes = 0;
    var full = false;
    for (final e in s.produced.entries) {
      if (_producing.contains(e.key)) continue;
      if (ids.length >= maxPackEntries || bytes + e.value > maxPackDataBytes) {
        full = true;
        break;
      }
      ids.add(e.key);
      bytes += e.value;
    }
    if (ids.length >= maxPackEntries) full = true;
    if (ids.isEmpty || (!all && !full)) return null;
    return ids;
  }

  /// Uploads (or finds) the pending pack, records it in the index and in
  /// `_packs_applied.json`, then marks its ids packed. Each step is
  /// persisted before the next, so any interruption resumes here.
  Future<void> _completePending(BackfillState s) async {
    final pend = s.pending!;
    if (pend.messageId == null) {
      ThumbPackRef? found;
      if (pend.uploadStarted) found = await _remote.findPack(pend.packId);
      if (found != null) {
        pend.messageId = found.messageId;
        pend.size = found.size;
      } else {
        final built = await _buildPack(pend);
        if (built == null) {
          s.pending = null;
          await _stateStore.save(s);
          return;
        }
        pend.uploadStarted = true;
        await _stateStore.save(s);
        try {
          pend.messageId = await _remote.uploadPack(built.path, pend.packId);
        } finally {
          try {
            await File(built.path).delete();
          } catch (_) {}
        }
        pend.size = built.size;
      }
      await _stateStore.save(s);
      _set(_progress.value.copyWith(packsUploaded: _progress.value.packsUploaded + 1));
      _log('pack uploaded entries=${pend.ids.length} size=${pend.size}');
    }
    final ref = pend.ref!;
    await _commitToIndex(ref, pend.ids);
    await _recordApplied(ref);
    s.packed.addAll(pend.ids);
    s.packs
      ..removeWhere((r) => r.messageId == ref.messageId)
      ..add(ref);
    s.pending = null;
    await _stateStore.save(s);
  }

  /// Writes the pending pack's file from the ThumbStore (off the UI
  /// isolate). Ids whose thumbnail is gone or damaged leave the pack and are
  /// dropped from the store, so they become candidates again.
  Future<({String path, int size})?> _buildPack(PendingPack pend) async {
    final dir = await _store.dirPath();
    final work = await _workDir();
    await work.create(recursive: true);
    final out = p.join(work.path, '${ThumbPackCodec.fileNameFor(pend.packId)}.tmp');
    final rows = <_PackRow>[
      for (final id in pend.ids)
        (id, p.join(dir, '$id.jpg'), _wireFor(id)),
    ];
    final built = await _writePackFileOffThread(pend.packId, pend.createdAt, rows, out);
    for (final id in built.bad) {
      await _store.reportCorrupt(id);
    }
    if (built.ids.isEmpty) {
      try {
        await File(out).delete();
      } catch (_) {}
      return null;
    }
    pend.ids = built.ids;
    return (path: out, size: built.size);
  }

  String? _wireFor(String id) {
    final h = _previews.hash(id);
    return h == null ? null : PreviewCodec.toWire(h);
  }

  Future<void> _commitToIndex(ThumbPackRef ref, List<String> ids) async {
    final previews = <String, String>{};
    for (final id in ids) {
      final w = _wireFor(id);
      if (w != null) previews[id] = w;
    }
    bool hasPack(FileIndex i) => i.thumbPacks.any((r) => r.messageId == ref.messageId);
    final cur = _indexAccess.current();
    if (cur != null && hasPack(cur) && identical(cur.withPreviews(previews), cur)) return;
    final written = await _indexAccess.write((i) {
      final withPack = hasPack(i) ? i : i.addThumbPack(ref);
      return withPack.withPreviews(previews);
    });
    if (!hasPack(written)) {
      throw const BackfillException('The index write did not keep the new pack; run again.');
    }
  }

  /// Packs listed in the index that this device has not applied are
  /// installed first (their thumbnails are not candidates). Returns the ids
  /// they covered.
  Future<Set<String>> _installIndexPacks(FileIndex index, BackfillState s) async {
    final covered = <String>{};
    final applied = await _readApplied();
    final dir = await _store.dirPath();
    for (final ref in index.thumbPacks) {
      if (applied['${ref.messageId}'] == ref.id) continue;
      if (_isOwnPack(s, ref)) {
        await _recordApplied(ref);
        continue;
      }
      if (_pauseRequested) break;
      final res = await _remote.installPack(
        PackInstallArgs(messageId: ref.messageId, packId: ref.id, dirPath: dir),
      );
      if (!res.ok) {
        if (res.permanent) {
          _log('pack ${ref.messageId} unusable, skipped');
          continue;
        }
        throw const BackfillException('Could not install an existing thumbnail pack; try again later.');
      }
      _store.markPresent(res.installedIds);
      final hashes = <String, Uint8List>{};
      res.previews.forEach((id, wire) {
        final h = PreviewCodec.fromWire(wire);
        if (h != null) hashes[id] = h;
      });
      if (hashes.isNotEmpty) _previews.putAll(hashes);
      covered.addAll(res.installedIds);
      await _recordApplied(ref);
    }
    return covered;
  }

  /// Step 5: items in a pack whose index entry has no preview get it, and
  /// packs this device made that the index lost are recorded again. One
  /// index write at most; none when nothing is missing.
  Future<int> _patch(BackfillState s, Set<String> installed) async {
    final covered = {...s.packed, ...installed};
    var patched = 0;
    FileIndex mutate(FileIndex i) {
      var next = i;
      for (final r in s.packs) {
        if (!next.thumbPacks.any((x) => x.messageId == r.messageId)) next = next.addThumbPack(r);
      }
      final previews = _previewPatches(next, covered);
      patched = previews.length;
      return next.withPreviews(previews);
    }

    final cur = _indexAccess.current();
    if (cur != null && identical(mutate(cur), cur)) return 0;
    await _indexAccess.write(mutate);
    return patched;
  }

  Map<String, String> _previewPatches(FileIndex index, Set<String> covered) {
    final out = <String, String>{};
    for (final f in index.files) {
      if (f.preview != null || !covered.contains(f.id)) continue;
      final w = _wireFor(f.id);
      if (w != null) out[f.id] = w;
    }
    return out;
  }

  static bool _isOwnPack(BackfillState s, ThumbPackRef ref) =>
      s.packs.any((r) => r.messageId == ref.messageId) ||
      (s.pending?.messageId == ref.messageId && s.pending?.packId == ref.id);

  // -------------------------------------------------------- bookkeeping

  /// `_packs_applied.json` in the thumbnail directory (shared with the
  /// prefetcher): merged, never replaced wholesale.
  Future<File> _appliedFile() async => File(p.join(await _store.dirPath(), '_packs_applied.json'));

  Future<Map<String, String>> _readApplied() async {
    final out = <String, String>{};
    try {
      final file = await _appliedFile();
      if (!await file.exists()) return out;
      final doc = jsonDecode(await file.readAsString());
      if (doc is Map && doc['v'] == 1 && doc['packs'] is Map) {
        (doc['packs'] as Map).forEach((k, v) {
          if (k is String && v is String) out[k] = v;
        });
      }
    } catch (_) {
      // Unreadable: packs are reinstalled (idempotent).
    }
    return out;
  }

  Future<void> _recordApplied(ThumbPackRef ref) async {
    try {
      (onPackApplied ?? ThumbPrefetcher.instance.markPackApplied)(ref.id, ref.messageId);
    } catch (_) {
      // In-memory hint only.
    }
    try {
      final applied = await _readApplied();
      if (applied['${ref.messageId}'] == ref.id) return;
      applied['${ref.messageId}'] = ref.id;
      final file = await _appliedFile();
      final tmp = File('${file.path}.backfill.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'packs': applied}), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Not fatal: the pack is reinstalled later (idempotent).
    }
  }

  void _fail(BackfillState s, FileItem f, String reason) {
    final old = s.failed[f.id];
    s.failed[f.id] = old == null ? BackfillFailure(mime: f.mimeType, reason: reason) : old.next(reason);
    _set(_progress.value.copyWith(
      failures: s.failed.length,
      processed: _progress.value.processed + 1,
    ));
  }

  void _needsDesktop(BackfillState s, FileItem f) {
    s.needsDesktop[f.id] = f.mimeType;
    s.failed.remove(f.id);
    _set(_progress.value.copyWith(
      needsDesktop: s.needsDesktop.length,
      processed: _progress.value.processed + 1,
    ));
  }

  ({List<FileItem> candidates, int mediaTotal, int failedSkipped, int desktopSkipped}) _scan(
    FileIndex index,
    BackfillState s, {
    required bool ffmpeg,
  }) {
    final pending = s.pending?.ids.toSet() ?? const <String>{};
    final out = <FileItem>[];
    var media = 0;
    var failedSkipped = 0;
    var desktopSkipped = 0;
    for (final f in index.files) {
      if (!_isImage(f) && !_isVideo(f)) continue;
      media++;
      if (f.parts.isEmpty) continue;
      final id = f.id;
      if (_store.has(id) || s.packed.contains(id) || s.produced.containsKey(id) || pending.contains(id)) {
        continue;
      }
      if (s.needsDesktop.containsKey(id) && !ffmpeg) {
        desktopSkipped++;
        continue;
      }
      final failure = s.failed[id];
      if (failure != null && failure.attempts >= maxAttempts) {
        failedSkipped++;
        continue;
      }
      out.add(f);
    }
    return (
      candidates: out,
      mediaTotal: media,
      failedSkipped: failedSkipped,
      desktopSkipped: desktopSkipped,
    );
  }

  Future<Map<int, BackfillProbe>> _probeAll(List<FileItem> items) async {
    final ids = <int>{for (final f in items) _firstMessageId(f)}.toList();
    final out = <int, BackfillProbe>{};
    for (var i = 0; i < ids.length; i += probeBatchSize) {
      final chunk = ids.sublist(i, math.min(i + probeBatchSize, ids.length));
      for (final pr in await _remote.probe(chunk)) {
        out[pr.messageId] = pr;
      }
    }
    return out;
  }

  _Route _route(FileItem f, BackfillProbe? probe, bool ffmpeg) {
    if (probe == null || !probe.exists) return _Route.missing;
    if (probe.hasServerThumb) return _Route.server;
    return _routeNoServer(f, ffmpeg);
  }

  _Route _routeNoServer(FileItem f, bool ffmpeg) {
    if (_isVideo(f)) return ffmpeg ? _Route.download : _Route.desktop;
    return (_codec.engineCanDecode(f.mimeType) || ffmpeg) ? _Route.download : _Route.desktop;
  }

  Future<Uint8List?> _safePreview(Uint8List jpeg) async {
    try {
      return await _codec.previewOf(jpeg);
    } catch (_) {
      return null;
    }
  }

  FileIndex _usableIndex() {
    final index = _indexAccess.current();
    if (index == null) {
      throw const BackfillBlockedException(
          'The index is loading or saving, or could not be loaded; try again in a moment.');
    }
    return index;
  }

  Future<void> _initStores() async {
    try {
      await _store.init();
    } catch (_) {
      throw const BackfillBlockedException('The thumbnail folder is not available.');
    }
    await _previews.init();
  }

  Future<void> _cleanWorkDir() async {
    final dir = await _workDir();
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    await dir.create(recursive: true);
  }

  Future<void> _discard(BackfillOriginal? original, String itemDir) async {
    if (original != null && original.owned) {
      try {
        if (await original.file.exists()) await original.file.delete();
      } catch (_) {}
    }
    try {
      final d = Directory(itemDir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  void _throwIfAborted() {
    final e = _abort;
    if (e != null) throw e;
  }

  void _set(BackfillProgress value) => _progress.value = value;

  static bool _isImage(FileItem f) => f.mimeType.startsWith('image/');
  static bool _isVideo(FileItem f) => f.mimeType.startsWith('video/');

  static int _firstMessageId(FileItem f) {
    var best = f.parts.first;
    for (final part in f.parts) {
      if (part.part < best.part) best = part;
    }
    return best.messageId;
  }

  /// Exception text that is safe to show (never a file name or path).
  static String _safeMessage(Object e) => switch (e) {
        BackfillBlockedException(:final message) => message,
        BackfillException(:final message) => message,
        _ => 'The backfill job stopped (${e.runtimeType}). Run it again to resume.',
      };

  static void _log(String message) => debugPrint('TVDIAG: backfill $message');

  static Future<Directory> _defaultWorkDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'televault_backfill'));
  }

  static Future<bool> _unmeteredNetwork() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }
}

typedef _PackRow = (String id, String path, String? preview);
typedef _BuiltPack = ({List<String> ids, List<String> bad, int size});

/// Top-level so the closure handed to `Isolate.run` captures only its
/// arguments.
Future<_BuiltPack> _writePackFileOffThread(
  String packId,
  DateTime createdAt,
  List<_PackRow> rows,
  String outPath,
) =>
    Isolate.run(() => _writePackFile(packId, createdAt, rows, outPath));

/// Runs on a helper isolate: reads each thumbnail, validates it and writes
/// the TVTP file to [outPath].
Future<_BuiltPack> _writePackFile(
  String packId,
  DateTime createdAt,
  List<_PackRow> rows,
  String outPath,
) async {
  final entries = <ThumbPackEntry>[];
  final bad = <String>[];
  for (final (id, path, preview) in rows) {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        bad.add(id);
        continue;
      }
      final jpeg = file.readAsBytesSync();
      final size = jpegSize(jpeg);
      if (!looksLikeJpeg(jpeg) || jpeg.length > ThumbPackCodec.maxBlobBytes || size == null ||
          size.w < 1 || size.h < 1) {
        bad.add(id);
        continue;
      }
      final validPreview = preview != null && PreviewCodec.fromWire(preview) != null ? preview : null;
      entries.add(ThumbPackEntry(id: id, jpeg: jpeg, width: size.w, height: size.h, preview: validPreview));
    } catch (_) {
      bad.add(id);
    }
  }
  if (entries.isEmpty) return (ids: const <String>[], bad: bad, size: 0);
  final bytes = ThumbPackCodec.encode(packId: packId, createdAt: createdAt, entries: entries);
  File(outPath).writeAsBytesSync(bytes, flush: true);
  return (ids: [for (final e in entries) e.id], bad: bad, size: bytes.length);
}

// ---------------------------------------------------------- defaults: remote

/// Argument of [probeBackfillMessages]. Plain data, sendable between isolates.
class BackfillProbeArgs {
  const BackfillProbeArgs(this.messageIds);
  final List<int> messageIds;
}

/// `messages.getMessages` for <= 100 ids per call: does each message exist
/// and does its document have a usable server thumbnail? Metadata only.
/// Top-level so it runs through `DownloadWorker.run`. Throws when a call
/// fails (a guess here would download originals needlessly).
Future<List<BackfillProbe>> probeBackfillMessages(BackfillProbeArgs args) async {
  final ids = args.messageIds;
  final out = <BackfillProbe>[];
  for (var i = 0; i < ids.length; i += kServerThumbMessagesPerCall) {
    final chunk = ids.sublist(i, math.min(i + kServerThumbMessagesPerCall, ids.length));
    final result = await withFloodWaitRetry(() => TelegramService.instance.call(
          (c) => c.messages.getMessages(id: [for (final id in chunk) t.InputMessageID(id: id)]),
        ));
    if (result.error != null) throw DownloadException('getMessages failed');
    final thumbs = <int, bool>{};
    for (final m in extractMessages(result.result)) {
      if (m is! t.Message) continue;
      final media = m.media;
      if (media is t.MessageMediaDocument && media.document is t.Document) {
        thumbs[m.id] = pickServerThumb((media.document as t.Document).thumbs) != null;
      }
    }
    for (final id in chunk) {
      out.add(BackfillProbe(id, exists: thumbs.containsKey(id), hasServerThumb: thumbs[id] ?? false));
    }
    WorkerProgress.report(out.length);
  }
  return out;
}

/// Argument of [uploadThumbPack]. Plain data, sendable between isolates.
class PackUploadArgs {
  const PackUploadArgs({required this.path, required this.packId});
  final String path;
  final String packId;
}

/// Uploads a TVTP file as one document in Saved Messages (format 7.2:
/// caption `TELEVAULT_THUMBS_V1 <pack_id>`, file name
/// `televault_thumbs_<pack_id>.tvtp`, application/octet-stream, forceFile,
/// no thumb) and returns its message id. Top-level so it runs through
/// `DownloadWorker.run`, like the index upload.
Future<int> uploadThumbPack(PackUploadArgs args) async {
  final bytes = await File(args.path).readAsBytes();
  if (bytes.isEmpty || bytes.length > kMaxPackDocumentBytes) {
    throw const BackfillException('Pack file has an invalid size.');
  }
  final fileId = randomInt64();
  const chunkSize = UploadLimits.chunkSize;
  final totalParts = (bytes.length + chunkSize - 1) ~/ chunkSize;
  for (var part = 0; part < totalParts; part++) {
    final start = part * chunkSize;
    final end = math.min(start + chunkSize, bytes.length);
    final chunk = Uint8List.sublistView(bytes, start, end);
    final result = await withFloodWaitRetry(() => TelegramService.instance.call(
          (c) => c.upload.saveFilePart(fileId: fileId, filePart: part, bytes: chunk),
        ));
    WorkerProgress.report(part);
    if (result.error != null) {
      throw BackfillException('Pack upload failed at part $part.');
    }
  }
  final name = ThumbPackCodec.fileNameFor(args.packId);
  final media = t.InputMediaUploadedDocument(
    nosoundVideo: false,
    forceFile: true,
    spoiler: false,
    file: t.InputFile(id: fileId, parts: totalParts, name: name, md5Checksum: ''),
    mimeType: 'application/octet-stream',
    attributes: [t.DocumentAttributeFilename(fileName: name)],
  );
  final randomId = randomInt64();
  final result = await withFloodWaitRetry(() => TelegramService.instance.call(
        (c) => c.messages.sendMedia(
          silent: true,
          background: false,
          clearDraft: false,
          noforwards: false,
          updateStickersetsOrder: false,
          invertMedia: false,
          allowPaidFloodskip: false,
          peer: const t.InputPeerSelf(),
          media: media,
          message: ThumbPackCodec.captionFor(args.packId),
          randomId: randomId,
        ),
      ));
  WorkerProgress.report(totalParts);
  if (result.error != null) throw const BackfillException('Sending the pack failed.');
  final id = extractSentMessageId(result.result, randomId);
  if (id == null) throw const BackfillException('Pack sent but its message id is unknown.');
  return id;
}

/// The production [BackfillRemote]: Telegram work runs on the download
/// worker isolate (its AES stays off the UI thread); originals come from the
/// device or the viewer cache when possible and are downloaded otherwise.
class WorkerBackfillRemote implements BackfillRemote {
  const WorkerBackfillRemote();

  @override
  Future<List<BackfillProbe>> probe(List<int> messageIds) async {
    final raw = await DownloadWorker.run<BackfillProbeArgs, List<Object?>>(
      probeBackfillMessages,
      BackfillProbeArgs(messageIds),
      inactivityTimeout: const Duration(seconds: 60),
    );
    return raw.whereType<BackfillProbe>().toList();
  }

  @override
  Future<List<ServerThumbResult>> serverThumbs(List<ServerThumbTarget> targets) async {
    final raw = await DownloadWorker.run<ServerThumbArgs, List<Object?>>(
      fetchServerThumbs,
      ServerThumbArgs(targets),
      inactivityTimeout: const Duration(seconds: 60),
    );
    return raw.whereType<ServerThumbResult>().toList();
  }

  @override
  Future<BackfillOriginal> fetchOriginal(FileItem item, String workDir) async {
    final ready = await DownloadService.instance.cachedFileFor(item);
    if (ready != null) return BackfillOriginal(ready, owned: false);
    await Directory(workDir).create(recursive: true);
    final file = await DownloadService.instance.downloadFile(item, destDir: workDir);
    return BackfillOriginal(file, owned: true);
  }

  @override
  Future<int> uploadPack(String path, String packId) => DownloadWorker.run<PackUploadArgs, int>(
        uploadThumbPack,
        PackUploadArgs(path: path, packId: packId),
        inactivityTimeout: const Duration(seconds: 120),
      );

  @override
  Future<ThumbPackRef?> findPack(String packId) async {
    final raw = await DownloadWorker.run<Object?, List<Object?>>(
      discoverPacks,
      null,
      inactivityTimeout: const Duration(seconds: 30),
    );
    for (final r in raw.whereType<ThumbPackRef>()) {
      if (r.id == packId) return r;
    }
    return null;
  }

  @override
  Future<PackInstallResult> installPack(PackInstallArgs args) =>
      DownloadWorker.run<PackInstallArgs, PackInstallResult>(
        installPack,
        args,
        inactivityTimeout: const Duration(seconds: 60),
      );
}

// ----------------------------------------------------------- defaults: codec

/// Engine decode (main isolate, natively subsampled) + JPEG encode on the
/// [ThumbEncoder] helper isolate; `ffmpeg` from PATH on Windows.
class EngineBackfillCodec implements BackfillCodec {
  EngineBackfillCodec();

  static const Set<String> _engineMimes = {
    'image/jpeg',
    'image/jpg',
    'image/pjpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/bmp',
    'image/x-ms-bmp',
    'image/vnd.wap.wbmp',
  };

  static const Set<String> _platformMimes = {'image/heic', 'image/heif'};

  Future<bool>? _ffmpeg;

  @override
  bool engineCanDecode(String mime) {
    final m = mime.toLowerCase();
    if (_engineMimes.contains(m)) return true;
    // Android decodes HEIF through the platform; the desktop engine does not.
    return Platform.isAndroid && _platformMimes.contains(m);
  }

  @override
  Future<bool> ffmpegAvailable() => _ffmpeg ??= _probeFfmpeg();

  static Future<bool> _probeFfmpeg() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('ffmpeg', const ['-hide_banner', '-version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<EncodedThumb?> encodeImage(File file) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final landscape = descriptor.width >= descriptor.height;
      var frame = await _decode(descriptor, byWidth: landscape);
      if (frame != null &&
          math.max(frame.width, frame.height) > kBackfillThumbSide) {
        // EXIF orientation swapped the axes: bound the other one.
        final other = await _decode(descriptor, byWidth: !landscape);
        if (other != null) {
          frame.dispose();
          frame = other;
        }
      }
      if (frame == null) return null;
      final image = frame;
      try {
        final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (raw == null) return null;
        final rgba = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
        final preview = PreviewCodec.encodeRgba(rgba, image.width, image.height);
        final jpeg = await ThumbEncoder.instance.encode(rgba, image.width, image.height);
        return EncodedThumb(jpeg, image.width, image.height, preview);
      } finally {
        image.dispose();
      }
    } catch (_) {
      return null;
    } finally {
      try {
        descriptor?.dispose();
      } catch (_) {}
      try {
        buffer?.dispose();
      } catch (_) {}
    }
  }

  static Future<ui.Image?> _decode(ui.ImageDescriptor d, {required bool byWidth}) async {
    ui.Codec? codec;
    try {
      codec = await d.instantiateCodec(
        targetWidth: byWidth ? math.min(kBackfillThumbSide, d.width) : null,
        targetHeight: byWidth ? null : math.min(kBackfillThumbSide, d.height),
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
    }
  }

  @override
  Future<EncodedThumb?> encodeWithFfmpeg(File file, String workDir) async {
    if (!await ffmpegAvailable()) return null;
    await Directory(workDir).create(recursive: true);
    final out = File(p.join(workDir, 'backfill_thumb.jpg'));
    try {
      final process = await Process.start('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-y',
        '-i',
        file.path,
        '-vf',
        'thumbnail=50,scale=$kBackfillThumbSide:$kBackfillThumbSide:force_original_aspect_ratio=decrease',
        '-frames:v',
        '1',
        '-q:v',
        '5',
        out.path,
      ]);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final code = await process.exitCode.timeout(const Duration(minutes: 2), onTimeout: () {
        process.kill();
        return -1;
      });
      if (code != 0 || !await out.exists()) return null;
      final jpeg = await out.readAsBytes();
      final size = jpegSize(jpeg);
      if (!looksLikeJpeg(jpeg) || size == null || jpeg.length > ThumbPackCodec.maxBlobBytes) {
        return null;
      }
      return EncodedThumb(jpeg, size.w, size.h, await previewOf(jpeg));
    } catch (_) {
      return null;
    } finally {
      try {
        if (await out.exists()) await out.delete();
      } catch (_) {}
    }
  }

  @override
  Future<Uint8List?> previewOf(Uint8List jpeg) => defaultPreviewFromJpeg(jpeg);
}
