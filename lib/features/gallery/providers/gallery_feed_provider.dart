import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../explorer/providers/index_provider.dart';
import '../models/gallery_entry.dart';
import '../services/capture_date_stamper.dart';
import '../services/gallery_feed_service.dart';
import '../services/undated_shape_diag.dart';

/// How long to wait for the state to settle before rebuilding the feed.
///
/// A batch upload bumps [deviceStateVersion] once per finished file, and each
/// bump re-ran everything below: three platform-channel round trips, a merge
/// of the whole library against the cloud index, and a sort of the result —
/// all on the UI thread, all while the user is scrolling the grid that is
/// about to be rebuilt. Uploading twenty photos meant doing that twenty times
/// for an answer that only differs at the end.
const _settleDelay = Duration(milliseconds: 400);

/// The flat, sorted (newest-first) unified Gallery feed. Recomputes whenever
/// the cloud index changes or [deviceStateVersion] is bumped (any
/// upload/download/delete anywhere in the app), coalescing bursts.
final galleryFeedProvider = FutureProvider<List<GalleryEntry>>((ref) async {
  // select: only the index itself matters, not isSaving/isLoading flips.
  final index = ref.watch(indexProvider.select((s) => s.index));
  ref.watch(deviceStateVersion);

  // Riverpod re-runs this body on every bump and disposes the previous run
  // first, so a burst leaves only the last run past the delay. The superseded
  // ones return a future that never completes, which leaves the provider on
  // the newer run's result rather than briefly publishing a stale one.
  var superseded = false;
  ref.onDispose(() => superseded = true);
  await Future<void>.delayed(_settleDelay);
  if (superseded) return Completer<List<GalleryEntry>>().future;

  final entries = await GalleryFeedService.instance.buildEntries(index);
  if (!superseded && ref.read(indexProvider.notifier).remoteSynced) {
    ref.read(captureDateStamperProvider).onFeedBuilt(entries);
    logUndatedShapesOnce(entries);
  }
  return entries;
});

/// The one-shot capture-date stamp of device/cloud pairs (see
/// [CaptureDateStamper]), fed by every [galleryFeedProvider] build.
final captureDateStamperProvider = Provider<CaptureDateStamper>((ref) {
  final stamper = CaptureDateStamper(
    isSynced: () => ref.read(indexProvider.notifier).remoteSynced,
    isIdle: () => ref.read(indexProvider.notifier).isIdle,
    applyAndSave: (mutate) =>
        ref.read(indexProvider.notifier).applyAndSave(mutate),
    linkedFileIdFor: BackupRegistry.instance.fileItemIdFor,
  );
  ref.onDispose(stamper.dispose);
  return stamper;
});

/// [galleryFeedProvider], grouped into month sections for the timeline UI.
final galleryMonthGroupsProvider =
    Provider<AsyncValue<List<GalleryMonthGroup>>>(
      (ref) => ref.watch(galleryFeedProvider).whenData(groupEntriesByMonth),
    );
