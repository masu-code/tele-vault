import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:tv_core/codecs.dart';
import 'package:tv_core/models.dart' show FileIndex, ThumbPackRef;

import 'backfill_state.dart';
import 'pack_coverage.dart';
import 'preview_table.dart';
import 'thumb_prefetcher.dart' show ThumbPrefetcher;
import 'thumb_store.dart';

/// Data bytes per pack the producers aim for (the format allows 8 MiB).
const int kPackDataBytes = 7 * 1024 * 1024 + 512 * 1024;

/// The job failed part-way; its state file lets the next run resume.
class BackfillException implements Exception {
  const BackfillException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The app's index as a background producer sees it.
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

/// The Telegram calls a pack producer needs. The only write is [uploadPack]
/// (`saveFilePart` + `sendMedia` of a pack document).
abstract class PackRemote {
  /// Sends the pack file at [path] as a document captioned
  /// `TELEVAULT_THUMBS_V1 <packId>`; returns its message id.
  Future<int> uploadPack(String path, String packId);

  /// The pack message with caption id [packId], if one is in Saved Messages.
  Future<ThumbPackRef?> findPack(String packId);
}

/// Publishes thumbnail packs from the [ThumbStore]: builds the TVTP file of a
/// [PendingPack], uploads it (or finds it again after a crash), records it in
/// the index, in `_packs_applied.json` and in the coverage cache. Shared by
/// the backfill job and the automatic packer.
class PackPublisher {
  PackPublisher({
    required BackfillIndexAccess index,
    required this.remote,
    required ThumbStore store,
    required this.previews,
    required this.stateStore,
    required this.workDir,
    PackCoverage? coverage,
    this.onPackApplied,
    void Function(String message)? log,
  })  : _indexAccess = index,
        _store = store,
        _coverage = coverage ?? PackCoverage(store),
        _log = log ?? ((_) {});

  final BackfillIndexAccess _indexAccess;
  final PackRemote remote;
  final ThumbStore _store;
  final PreviewTable previews;
  final BackfillStateStore stateStore;
  final Future<Directory> Function() workDir;
  final PackCoverage _coverage;
  final void Function(String message) _log;

  /// Tells the prefetcher a pack is applied on this device. Defaults to
  /// [ThumbPrefetcher.markPackApplied] on its singleton.
  final void Function(String packId, int messageId)? onPackApplied;

  /// Uploads (or finds) the pending pack of [s], records it in the index and
  /// in `_packs_applied.json`, then marks its ids packed. Each step is
  /// persisted before the next, so any interruption resumes here.
  /// [onUploaded] runs once the pack document is in Saved Messages.
  Future<void> completePending(BackfillState s, {void Function()? onUploaded}) async {
    final pend = s.pending!;
    if (pend.messageId == null) {
      ThumbPackRef? found;
      if (pend.uploadStarted) found = await remote.findPack(pend.packId);
      if (found != null) {
        pend.messageId = found.messageId;
        pend.size = found.size;
      } else {
        final built = await buildPack(pend);
        if (built == null) {
          s.pending = null;
          await stateStore.save(s);
          return;
        }
        pend.uploadStarted = true;
        await stateStore.save(s);
        try {
          pend.messageId = await remote.uploadPack(built.path, pend.packId);
        } finally {
          try {
            await File(built.path).delete();
          } catch (_) {}
        }
        pend.size = built.size;
      }
      await stateStore.save(s);
      onUploaded?.call();
      _log('pack uploaded entries=${pend.ids.length} size=${pend.size}');
    }
    final ref = pend.ref!;
    // Coverage is known without any download: the ids are ours.
    await _coverage.record(ref.messageId, ref.id, pend.ids);
    await commitToIndex(ref, pend.ids);
    await recordApplied(ref);
    s.packed.addAll(pend.ids);
    s.packs
      ..removeWhere((r) => r.messageId == ref.messageId)
      ..add(ref);
    s.pending = null;
    await stateStore.save(s);
  }

  /// Writes the pending pack's file from the ThumbStore (off the UI
  /// isolate). Ids whose thumbnail is gone or damaged leave the pack and are
  /// dropped from the store, so they become candidates again.
  Future<({String path, int size})?> buildPack(PendingPack pend) async {
    final dir = await _store.dirPath();
    final work = await workDir();
    await work.create(recursive: true);
    final out = p.join(work.path, '${ThumbPackCodec.fileNameFor(pend.packId)}.tmp');
    final rows = <_PackRow>[
      for (final id in pend.ids)
        (id, p.join(dir, '$id.jpg'), wireFor(id)),
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

  /// The `th1:` preview of [id] from the preview table, if any.
  String? wireFor(String id) {
    final h = previews.hash(id);
    return h == null ? null : PreviewCodec.toWire(h);
  }

  /// One index write that adds [ref] and the previews of [ids]; none when
  /// the index already has both.
  Future<void> commitToIndex(ThumbPackRef ref, List<String> ids) async {
    final previews = <String, String>{};
    for (final id in ids) {
      final w = wireFor(id);
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

  /// `_packs_applied.json` in the thumbnail directory (shared with the
  /// prefetcher): merged, never replaced wholesale.
  Future<File> _appliedFile() async => File(p.join(await _store.dirPath(), '_packs_applied.json'));

  Future<Map<String, String>> readApplied() async {
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

  Future<void> recordApplied(ThumbPackRef ref) async {
    try {
      (onPackApplied ?? ThumbPrefetcher.instance.markPackApplied)(ref.id, ref.messageId);
    } catch (_) {
      // In-memory hint only.
    }
    try {
      final applied = await readApplied();
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
