import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../explorer/providers/index_provider.dart';
import '../models/gallery_entry.dart';
import '../services/gallery_feed_service.dart';

/// The flat, sorted (newest-first) unified Gallery feed. Recomputes whenever
/// the cloud index changes or [deviceStateVersion] is bumped (any
/// upload/download/delete anywhere in the app).
final galleryFeedProvider = FutureProvider<List<GalleryEntry>>((ref) {
  final index = ref.watch(indexProvider).index;
  ref.watch(deviceStateVersion);
  return GalleryFeedService.instance.buildEntries(index);
});

/// [galleryFeedProvider], grouped into month sections for the timeline UI.
final galleryMonthGroupsProvider = Provider<AsyncValue<List<GalleryMonthGroup>>>(
  (ref) => ref.watch(galleryFeedProvider).whenData(groupEntriesByMonth),
);
