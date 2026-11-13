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

/// Least time between the end of one feed build and the start of the next.
///
/// The settle delay only merges changes that arrive closer together than it;
/// a queue run writes the index once per flushed batch, and on fast uploads
/// (plus the capture-date stamp and thumbnail backfill writes) those land a
/// second or so apart, each one a full rebuild. Changes arriving inside this
/// window are folded into one build at its end.
const _minBuildInterval = Duration(milliseconds: 1500);

/// When the last feed build's [_minBuildInterval] ends, per container.
final _feedCooldownProvider = Provider<_FeedCooldown>((ref) => _FeedCooldown());

class _FeedCooldown {
  Future<void>? until;
}

/// The flat, sorted (newest-first) unified Gallery feed. Recomputes whenever
/// the cloud index changes or [deviceStateVersion] is bumped (any
/// upload/download/delete anywhere in the app), coalescing bursts: at most
/// one build per [_minBuildInterval]. An unchanged feed comes back as the
/// same list, and unchanged entries as the same instances (see [adoptFeed]).
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
  final cooldown = ref.read(_feedCooldownProvider);
  await Future<void>.delayed(_settleDelay);
  if (superseded) return Completer<List<GalleryEntry>>().future;
  final wait = cooldown.until;
  if (wait != null) {
    await wait;
    if (superseded) return Completer<List<GalleryEntry>>().future;
  }

  final entries = await GalleryFeedService.instance.buildEntries(index);
  cooldown.until = Future<void>.delayed(_minBuildInterval);
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
///
/// A rebuild triggered by [Ref.watch] (an index change, a [deviceStateVersion]
/// bump) leaves [galleryFeedProvider] in an [AsyncLoading] that still holds
/// the previous feed, and `whenData` drops that value: the screen then saw a
/// bare loading state, swapped the whole grid for a spinner and back, and
/// re-created every tile (and its Scrollable) on each finished upload batch.
/// The previous feed's groups are kept through the reload instead.
final galleryMonthGroupsProvider =
    Provider<AsyncValue<List<GalleryMonthGroup>>>((ref) {
      final feed = ref.watch(galleryFeedProvider);
      final previous = feed.valueOrNull;
      if (feed is AsyncLoading && previous != null) {
        return AsyncLoading<List<GalleryMonthGroup>>().copyWithPrevious(
          AsyncData(groupEntriesByMonth(previous)),
          isRefresh: false,
        );
      }
      return feed.whenData(groupEntriesByMonth);
    });
