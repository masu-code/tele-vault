import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:tv_core/models.dart' show ThumbPackRef;

/// Why one item could not be backfilled. Ids and mime types only: never a
/// file name, caption or path.
@immutable
class BackfillFailure {
  const BackfillFailure({required this.mime, required this.reason, this.attempts = 1});

  factory BackfillFailure.fromJson(Map<String, dynamic> json) => BackfillFailure(
        mime: json['mime'] as String? ?? '',
        reason: json['reason'] as String? ?? '',
        attempts: json['n'] as int? ?? 1,
      );

  final String mime;
  final String reason;
  final int attempts;

  BackfillFailure next(String reason) =>
      BackfillFailure(mime: mime, reason: reason, attempts: attempts + 1);

  Map<String, dynamic> toJson() => {'mime': mime, 'reason': reason, 'n': attempts};
}

/// A pack that was started but is not yet recorded in the index. Kept in the
/// state file so a crash at any point resumes it instead of producing a
/// second pack with the same thumbnails.
class PendingPack {
  PendingPack({
    required this.packId,
    required this.createdAt,
    required this.ids,
    this.messageId,
    this.size,
    this.uploadStarted = false,
  });

  factory PendingPack.fromJson(Map<String, dynamic> json) => PendingPack(
        packId: json['pack_id'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        ids: [for (final id in json['ids'] as List<dynamic>) id as String],
        messageId: json['message_id'] as int?,
        size: json['size'] as int?,
        uploadStarted: json['upload_started'] as bool? ?? false,
      );

  final String packId;
  final DateTime createdAt;

  /// The thumbnails in the pack, in pack order.
  List<String> ids;

  /// Set once the pack document is in Saved Messages.
  int? messageId;
  int? size;

  /// True once an upload may have reached Telegram: a resume first looks for
  /// the pack by its caption before uploading again.
  bool uploadStarted;

  ThumbPackRef? get ref {
    final m = messageId;
    final s = size;
    if (m == null || s == null) return null;
    return ThumbPackRef(id: packId, messageId: m, count: ids.length, size: s, createdAt: createdAt);
  }

  Map<String, dynamic> toJson() => {
        'pack_id': packId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'ids': ids,
        if (messageId != null) 'message_id': messageId,
        if (size != null) 'size': size,
        'upload_started': uploadStarted,
      };
}

/// Everything the backfill job must remember between runs
/// (`<appSupport>/backfill_state.json`, plus an append-only journal of the
/// thumbnails produced since the last save).
class BackfillState {
  BackfillState();

  factory BackfillState.fromJson(Map<String, dynamic> json) {
    final s = BackfillState();
    final produced = json['produced'];
    if (produced is Map) {
      produced.forEach((k, v) {
        if (k is String && v is int) s.produced[k] = v;
      });
    }
    for (final id in json['packed'] as List<dynamic>? ?? const []) {
      if (id is String) s.packed.add(id);
    }
    for (final r in json['packs'] as List<dynamic>? ?? const []) {
      if (r is Map<String, dynamic>) s.packs.add(ThumbPackRef.fromJson(r));
    }
    final pending = json['pending'];
    if (pending is Map<String, dynamic>) s.pending = PendingPack.fromJson(pending);
    final failed = json['failed'];
    if (failed is Map) {
      failed.forEach((k, v) {
        if (k is String && v is Map<String, dynamic>) s.failed[k] = BackfillFailure.fromJson(v);
      });
    }
    final desktop = json['needs_desktop'];
    if (desktop is Map) {
      desktop.forEach((k, v) {
        if (k is String && v is String) s.needsDesktop[k] = v;
      });
    }
    s.bytesDownloaded = json['bytes_downloaded'] as int? ?? 0;
    final last = json['last_run_at'];
    if (last is String) s.lastRunAt = DateTime.tryParse(last);
    s.lastResult = json['last_result'] as String?;
    return s;
  }

  static const int version = 1;

  /// Thumbnails written to the ThumbStore by the job and not yet in a pack:
  /// id -> JPEG size, in production order.
  final LinkedHashMap<String, int> produced = LinkedHashMap<String, int>();

  /// Ids inside a pack that is recorded in the index.
  final Set<String> packed = <String>{};

  /// Packs this device created (re-added to the index if a later write
  /// lost them).
  final List<ThumbPackRef> packs = <ThumbPackRef>[];

  PendingPack? pending;

  /// id -> last failure (retried on later runs up to a limit).
  final Map<String, BackfillFailure> failed = <String, BackfillFailure>{};

  /// id -> mime of items only a desktop with ffmpeg can turn into a
  /// thumbnail (videos without a server thumbnail, formats the engine
  /// cannot decode).
  final Map<String, String> needsDesktop = <String, String>{};

  int bytesDownloaded = 0;
  DateTime? lastRunAt;
  String? lastResult;

  Map<String, dynamic> toJson() => {
        'v': version,
        'produced': produced,
        'packed': packed.toList(),
        'packs': [for (final r in packs) r.toJson()],
        if (pending != null) 'pending': pending!.toJson(),
        'failed': {for (final e in failed.entries) e.key: e.value.toJson()},
        'needs_desktop': needsDesktop,
        'bytes_downloaded': bytesDownloaded,
        if (lastRunAt != null) 'last_run_at': lastRunAt!.toUtc().toIso8601String(),
        if (lastResult != null) 'last_result': lastResult,
      };
}

/// Persists [BackfillState] crash-safely: the JSON file is replaced with a
/// tmp + rename, and every thumbnail produced between two saves is appended
/// to a journal first, so a thumbnail that is in the ThumbStore is never
/// forgotten by the job (it would otherwise never reach a pack).
class BackfillStateStore {
  BackfillStateStore(this._resolveDir);

  static const String stateFileName = 'backfill_state.json';
  static const String journalFileName = 'backfill_produced.log';

  final Future<Directory> Function() _resolveDir;
  Future<void> _io = Future<void>.value();

  Future<File> _file(String name) async {
    final dir = await _resolveDir();
    await dir.create(recursive: true);
    return File(p.join(dir.path, name));
  }

  /// The saved state plus the journal replayed on top of it. An unreadable
  /// state file starts over (thumbnails already in the store are not
  /// candidates again, so nothing is redone; only bookkeeping is lost).
  Future<BackfillState> load() async {
    BackfillState state;
    try {
      final file = await _file(stateFileName);
      if (await file.exists()) {
        final doc = jsonDecode(await file.readAsString());
        state = doc is Map<String, dynamic> && doc['v'] == BackfillState.version
            ? BackfillState.fromJson(doc)
            : BackfillState();
      } else {
        state = BackfillState();
      }
    } catch (_) {
      state = BackfillState();
    }
    try {
      final journal = await _file(journalFileName);
      if (await journal.exists()) {
        final inPending = state.pending?.ids.toSet() ?? const <String>{};
        for (final line in const LineSplitter().convert(await journal.readAsString())) {
          final sp = line.indexOf(' ');
          if (sp <= 0) continue;
          final id = line.substring(0, sp);
          final len = int.tryParse(line.substring(sp + 1));
          if (len == null || len <= 0) continue; // torn last line
          if (state.packed.contains(id) || inPending.contains(id)) continue;
          state.produced[id] = len;
        }
      }
    } catch (_) {
      // A lost journal only means those thumbnails wait for a later pack.
    }
    return state;
  }

  /// Records one produced thumbnail before anything else depends on it.
  Future<void> appendProduced(String id, int length) => _serial(() async {
        final journal = await _file(journalFileName);
        await journal.writeAsString('$id $length\n', mode: FileMode.append, flush: true);
      });

  /// Writes the whole state (which includes every journaled entry) and
  /// empties the journal.
  Future<void> save(BackfillState state) {
    final text = jsonEncode(state.toJson());
    return _serial(() async {
      final file = await _file(stateFileName);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
      final journal = await _file(journalFileName);
      if (await journal.exists()) await journal.writeAsString('', flush: true);
    });
  }

  Future<void> _serial(Future<void> Function() op) {
    final next = _io.then((_) => op());
    _io = next.catchError((Object _) {});
    return next;
  }
}

/// What a run would do, computed without downloading anything.
@immutable
class BackfillPlan {
  const BackfillPlan({
    required this.mediaTotal,
    required this.candidates,
    required this.serverThumbs,
    required this.imagesToDownload,
    required this.videosToDownload,
    required this.needsDesktop,
    required this.missing,
    required this.bytesToDownload,
    required this.awaitingPack,
    required this.packed,
    required this.skippedFailures,
    required this.packsToInstall,
    required this.packBytesToInstall,
    required this.previewPatches,
    required this.candidatesByMime,
  });

  /// Images and videos in the index (archived included).
  final int mediaTotal;

  /// Items with no thumbnail in the store and no pack entry.
  final int candidates;
  final int serverThumbs;
  final int imagesToDownload;
  final int videosToDownload;
  final int needsDesktop;

  /// Candidates whose Telegram message could not be found.
  final int missing;

  /// Bytes of originals a run would download.
  final int bytesToDownload;

  /// Thumbnails already made and waiting for a pack.
  final int awaitingPack;
  final int packed;

  /// Items left out because they failed too many times.
  final int skippedFailures;

  /// Packs in the index not installed on this device yet. While > 0, the
  /// counts above are an upper bound (a pack may cover some candidates).
  final int packsToInstall;
  final int packBytesToInstall;

  /// Items already in a pack whose index entry lacks a preview.
  final int previewPatches;
  final Map<String, int> candidatesByMime;

  bool get isUpperBound => packsToInstall > 0;
}

enum BackfillPhase { idle, planning, preparing, serverThumbs, downloading, packing, patching, paused, done, failed }

/// Live progress for the screen. Counts only.
@immutable
class BackfillProgress {
  const BackfillProgress({
    this.phase = BackfillPhase.idle,
    this.total = 0,
    this.processed = 0,
    this.produced = 0,
    this.packsUploaded = 0,
    this.failures = 0,
    this.needsDesktop = 0,
    this.bytesDownloaded = 0,
    this.error,
  });

  final BackfillPhase phase;

  /// Candidates this run works on, and how many are finished either way.
  final int total;
  final int processed;
  final int produced;
  final int packsUploaded;
  final int failures;
  final int needsDesktop;
  final int bytesDownloaded;
  final String? error;

  bool get running =>
      phase != BackfillPhase.idle &&
      phase != BackfillPhase.paused &&
      phase != BackfillPhase.done &&
      phase != BackfillPhase.failed;

  BackfillProgress copyWith({
    BackfillPhase? phase,
    int? total,
    int? processed,
    int? produced,
    int? packsUploaded,
    int? failures,
    int? needsDesktop,
    int? bytesDownloaded,
    String? error,
  }) =>
      BackfillProgress(
        phase: phase ?? this.phase,
        total: total ?? this.total,
        processed: processed ?? this.processed,
        produced: produced ?? this.produced,
        packsUploaded: packsUploaded ?? this.packsUploaded,
        failures: failures ?? this.failures,
        needsDesktop: needsDesktop ?? this.needsDesktop,
        bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
        error: error,
      );
}

/// Outcome of one [BackfillService.run].
@immutable
class BackfillRunResult {
  const BackfillRunResult({
    required this.produced,
    required this.packsUploaded,
    required this.previewsPatched,
    required this.needsDesktop,
    required this.failures,
    required this.paused,
    this.more = false,
  });

  final int produced;
  final int packsUploaded;
  final int previewsPatched;
  final int needsDesktop;

  /// id -> failure (ids and mime types only).
  final Map<String, BackfillFailure> failures;
  final bool paused;

  /// A chunked run (`maxCandidates`) left candidates for a later run.
  final bool more;
}
