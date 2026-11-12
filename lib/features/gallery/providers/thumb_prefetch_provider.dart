import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tv_core/models.dart' show ThumbPackRef;

import '../../../core/thumbnail/preview_table.dart';
import '../../../core/thumbnail/thumb_prefetcher.dart';
import '../../../core/thumbnail/thumb_store.dart';
import '../../explorer/providers/index_provider.dart';
import '../models/gallery_entry.dart';
import 'gallery_feed_provider.dart';

/// Wires the gallery's data to the [ThumbPrefetcher]. Read it once (the
/// gallery screen does, in `initState`); it then lives for the whole app:
///
///  * starts the [ThumbStore] and the [PreviewTable] and imports the previews
///    stored in the cloud index;
///  * hands the prefetcher the library in feed order (and the index's
///    thumbnail packs) whenever either changes;
///  * pauses background work while the app is not in the foreground
///    (scrolling is handled by [handleGalleryScroll]).
final thumbPrefetchBindingProvider = Provider<void>((ref) {
  final binding = _ThumbPrefetchBinding(ThumbPrefetcher.instance)..start();

  ref.listen<List<GalleryEntry>?>(
    galleryFeedProvider.select((a) => a.valueOrNull),
    (_, feed) {
      if (feed != null) binding.setFeed(feed);
    },
    fireImmediately: true,
  );
  ref.listen<IndexState>(
    indexProvider,
    (_, state) => binding.setIndex(state),
    fireImmediately: true,
  );

  ref.onDispose(binding.dispose);
});

/// Pauses the prefetcher's background work while a list scrolls and resumes it
/// when the list comes to rest. Use as a `NotificationListener` callback; it
/// never absorbs the notification.
bool handleGalleryScroll(ScrollNotification n) {
  if (n.depth != 0) return false;
  if (n is ScrollStartNotification) {
    ThumbPrefetcher.instance.pause();
  } else if (n is ScrollEndNotification) {
    ThumbPrefetcher.instance.resume();
  }
  return false;
}

class _ThumbPrefetchBinding {
  _ThumbPrefetchBinding(this._prefetcher);

  final ThumbPrefetcher _prefetcher;
  AppLifecycleListener? _lifecycle;

  List<GalleryEntry> _feed = const [];
  List<ThumbPackRef> _packs = const [];
  Object? _importedFiles;

  void start() {
    // Both are inert (and never throw out of here) without path_provider.
    ThumbStore.instance.init().catchError((Object _) {});
    PreviewTable.instance.init();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) {
          _prefetcher.resume();
        } else {
          _prefetcher.pause();
        }
      },
    );
  }

  void dispose() => _lifecycle?.dispose();

  void setFeed(List<GalleryEntry> feed) {
    if (identical(feed, _feed)) return;
    _feed = feed;
    _push();
  }

  void setIndex(IndexState state) {
    final index = state.index;
    // `files` is replaced, never mutated, so identity says "nothing new".
    if (!identical(index.files, _importedFiles)) {
      _importedFiles = index.files;
      PreviewTable.instance.importFromIndex(index.files);
    }
    if (!_samePacks(index.thumbPacks, _packs)) {
      _packs = index.thumbPacks;
      _push();
    }
  }

  void _push() {
    _prefetcher.updateLibrary(
      inFeedOrder: [
        for (final e in _feed)
          ThumbRequest(
            key: e.thumbKey,
            file: e.fileItem,
            assetId: e.asset?.id,
            asset: e.asset,
          ),
      ],
      packs: _packs,
    );
  }

  static bool _samePacks(List<ThumbPackRef> a, List<ThumbPackRef> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].messageId != b[i].messageId || a[i].id != b[i].id) return false;
    }
    return true;
  }
}
