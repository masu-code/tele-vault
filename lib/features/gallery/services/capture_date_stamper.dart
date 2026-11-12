import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import '../../../models/capture_date.dart';
import '../../../models/file_index.dart';
import '../models/gallery_entry.dart';

/// Most items one stamp save writes.
/// One save covers the whole job: every stamp save re-uploads the full index,
/// so smaller batches only multiply uploads, flood-wait exposure and backups.
const int captureStampBatchSize = 100000;

/// Cloud items of [entries] that are paired with a device asset, have no
/// stored `taken_at`, and whose asset gives a believable capture date:
/// file id -> [deviceCaptureMs], at most [limit], in feed order.
///
/// The value is exactly the date the paired entry already shows (a paired
/// entry is dated by its asset), so writing it changes no position in the
/// feed; once the device copy is gone the cloud item keeps that date instead
/// of falling back to its upload time.
Map<String, int> pendingCaptureStamps(
  List<GalleryEntry> entries, {
  int limit = captureStampBatchSize,
  String? Function(String assetId)? linkedFileIdFor,
}) {
  final out = <String, int>{};
  for (final e in entries) {
    if (out.length >= limit) break;
    final asset = e.asset, f = e.fileItem;
    if (asset == null || f == null || hasStoredTakenAt(f)) continue;
    // Only registry-linked pairs (verified upload of THIS asset). A pair made
    // by the unique-name fallback may be a different photo with the same
    // name, and the stamp is permanent.
    if (linkedFileIdFor != null && linkedFileIdFor(asset.id) != f.id) continue;
    final ms = deviceCaptureMs(asset);
    if (ms != null) out[f.id] = ms;
  }
  return out;
}

/// One-shot stamp of every device/cloud pair the Gallery feed knows: stores
/// the device capture date as `taken_at` on the cloud item, so the date
/// survives any later loss of the device copy (Free up space, a delete in the
/// system gallery, another device reading the vault).
///
/// Fed by each feed build ([onFeedBuilt]); debounced; at most one batch of
/// [batchSize] per build, through [applyAndSave] (the index notifier's
/// serialized write path); never while a mutation is in flight ([isIdle]) or
/// before the index was read from Telegram ([isSynced]). Idempotent: stamped
/// items are skipped, so the next build after a save picks the next batch and
/// the job stops by itself. Records nothing besides `taken_at`.
class CaptureDateStamper {
  CaptureDateStamper({
    required this.isSynced,
    required this.isIdle,
    required this.applyAndSave,
    this.linkedFileIdFor,
    this.debounce = const Duration(seconds: 3),
    this.batchSize = captureStampBatchSize,
    this.failureBackoff = const Duration(minutes: 5),
  });

  final bool Function() isSynced;
  final bool Function() isIdle;
  final Future<FileIndex> Function(FileIndex Function(FileIndex current) mutate)
      applyAndSave;

  /// Registry link of a device asset (BackupRegistry.fileItemIdFor). When set,
  /// only pairs whose link matches are stamped.
  final String? Function(String assetId)? linkedFileIdFor;
  final Duration debounce;
  final int batchSize;

  /// After a failed save, no new attempt for this long (a failure rolls the
  /// index back, which rebuilds the feed and would retry right away).
  final Duration failureBackoff;

  Timer? _timer;
  List<GalleryEntry>? _latest;
  bool _running = false;
  bool _disposed = false;
  DateTime? _failedAt;

  /// Called after each feed build with its entries. Schedules one batch when
  /// something is pending; cheap no-op otherwise.
  void onFeedBuilt(List<GalleryEntry> entries) {
    if (_disposed || !isSynced()) return;
    if (pendingCaptureStamps(entries, limit: 1, linkedFileIdFor: linkedFileIdFor).isEmpty) {
      _latest = null;
      _timer?.cancel();
      _timer = null;
      return;
    }
    _latest = entries;
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(_fire()));
  }

  /// Runs the pending batch now instead of after the debounce.
  @visibleForTesting
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _fire();
  }

  Future<void> _fire() async {
    _timer = null;
    final entries = _latest;
    if (_disposed || entries == null || !isSynced()) return;
    final failedAt = _failedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < failureBackoff) {
      return;
    }
    if (_running || !isIdle()) {
      _timer = Timer(debounce, () => unawaited(_fire()));
      return;
    }
    final batch = pendingCaptureStamps(entries, limit: batchSize, linkedFileIdFor: linkedFileIdFor);
    _latest = null;
    if (batch.isEmpty) return;
    _running = true;
    try {
      await applyAndSave((current) => stampTakenAt(current, batch));
      _failedAt = null;
    } catch (e) {
      _failedAt = DateTime.now();
      debugPrint('TVDIAG: capture stamp failed n=${batch.length} '
          '(${e.runtimeType})');
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
