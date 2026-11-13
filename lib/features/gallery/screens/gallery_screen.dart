import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/backup/asset_upload_service.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/diag/tv_stats.dart';
import '../../../core/download/download_service.dart';
import '../../backup/providers/backup_provider.dart';
import '../../download/providers/download_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../preview/screens/mixed_media_viewer_screen.dart';
import '../../preview/widgets/add_to_album_sheet.dart';
import '../../preview/widgets/delete_source_dialog.dart';
import '../../profile/widgets/floating_profile_header.dart';
import '../../shell/scroll_to_top.dart';
import '../../transfer/providers/transfer_queue_provider.dart';
import '../../../core/thumbnail/thumb_prefetcher.dart';
import '../models/gallery_entry.dart';
import '../providers/gallery_feed_provider.dart';
import '../providers/thumb_prefetch_provider.dart';
import '../services/gallery_feed_service.dart';
import '../widgets/fast_scrollbar.dart';
import '../widgets/gallery_tile.dart';

/// Google Photos-style timeline of ALL media, grouped by month — both
/// already-uploaded cloud files and device-only photos/videos merged into
/// one feed (see [galleryFeedProvider]). Tap opens the full-screen viewer;
/// long-press (or right-click) starts multi-select, with upload/download,
/// add-to-album, and delete actions in the app bar.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen>
    with WidgetsBindingObserver {
  /// Selected entry keys. Tiles and the selection app bar listen to it
  /// directly, so toggling an item rebuilds neither this screen nor the
  /// slivers; only entering/leaving selection mode (empty <-> not empty) does.
  final ValueNotifier<Set<String>> _selection = ValueNotifier(const {});
  bool _selecting = false;
  final ScrollController _scrollController = ScrollController();

  // Slivers are rebuilt only when one of these changes (see _slivers).
  List<Widget>? _sliverCache;
  List<GalleryMonthGroup>? _cachedGroups;
  List<GalleryEntry>? _cachedFlat;
  double? _cachedTopInset;
  bool? _cachedBanner;

  /// Slivers of each month section and the tile of each entry, by instance
  /// (see [_slivers]). Weak: they go with the feed that held them.
  final Expando<List<Widget>> _groupSlivers = Expando();
  final Expando<Widget> _tiles = Expando();

  /// The current flat feed, read by a tile's tap at tap time.
  List<GalleryEntry> _flat = const [];

  /// Whether this device has granted (full or limited) photo library access.
  /// Null while the initial passive check is in flight; false shows the
  /// opt-in banner (never requested automatically — see initState).
  bool? _hasDeviceAccess;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selection.addListener(_onSelectionChanged);
    ref.read(thumbPrefetchBindingProvider);
    _checkDeviceAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission can change while this screen never rebuilds on its own:
    // granted from the Albums tab's own request flow (MainShell keeps every
    // tab alive in an IndexedStack, so Gallery's initState only ever runs
    // once), or from system Settings entirely outside the app. Either way,
    // coming back to the foreground is exactly when that could have
    // happened — re-check then instead of only once at startup, which used
    // to mean the feed stayed empty until a full app restart.
    if (state == AppLifecycleState.resumed) _checkDeviceAccess();
  }

  void _checkDeviceAccess() {
    if (!Platform.isAndroid) {
      _hasDeviceAccess = false;
      return;
    }
    PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(),
    ).then((s) {
      if (!mounted) return;
      final gained = _hasDeviceAccess != true && s.hasAccess;
      setState(() => _hasDeviceAccess = s.hasAccess);
      if (gained) ref.invalidate(galleryFeedProvider);
    });
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _grantDeviceAccess() async {
    final state = await PhotoManager.requestPermissionExtend();
    if (mounted) setState(() => _hasDeviceAccess = state.hasAccess);
    ref.invalidate(galleryFeedProvider);
    // The Albums tab's device albums come from a separate, once-only load
    // that already ran (and found nothing) back when there was no
    // permission — without this, granting access here would repopulate the
    // Gallery timeline but leave Albums empty until the next app restart.
    if (state.hasAccess) {
      unawaited(ref.read(backupProvider.notifier).loadDeviceAlbums());
    }
  }

  // Rebuilds the screen only when selection mode starts or ends.
  void _onSelectionChanged() {
    final selecting = _selection.value.isNotEmpty;
    if (selecting != _selecting && mounted) {
      setState(() => _selecting = selecting);
    }
  }

  void _exitSelection() => _selection.value = const {};

  void _toggle(GalleryEntry entry) {
    final next = Set<String>.of(_selection.value);
    if (!next.remove(entry.key)) next.add(entry.key);
    _selection.value = next;
  }

  void _startSelection(GalleryEntry entry) {
    _selection.value = {..._selection.value, entry.key};
  }

  List<GalleryEntry> _selectedEntries(List<GalleryEntry> flat) {
    final selected = _selection.value;
    return flat.where((e) => selected.contains(e.key)).toList();
  }

  Future<void> _shareSelected(List<GalleryEntry> flat) async {
    final selected = _selectedEntries(flat);
    if (selected.isEmpty) return;
    try {
      final locals = await Future.wait(
        selected.map((e) async {
          if (e.fileItem != null)
            return DownloadService.instance.downloadToCache(e.fileItem!);
          final f = await e.asset!.file;
          if (f == null) throw Exception('Could not read file from device.');
          return f;
        }),
      );
      await SharePlus.instance.share(
        ShareParams(files: locals.map((f) => XFile(f.path)).toList()),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not share: $e')));
      }
    }
  }

  void _uploadSelected(List<GalleryEntry> flat) {
    final toUpload = _selectedEntries(
      flat,
    ).where((e) => e.fileItem == null).map((e) => e.asset!).toList();
    if (toUpload.isEmpty) return;
    _exitSelection();
    ref.read(transferQueueProvider.notifier).enqueueUploads(toUpload);
  }

  void _downloadSelected(List<GalleryEntry> flat) {
    final toDownload = _selectedEntries(flat)
        .where((e) => e.fileItem != null && e.asset == null)
        .map((e) => e.fileItem!)
        .toList();
    if (toDownload.isEmpty) return;
    _exitSelection();
    ref.read(transferQueueProvider.notifier).enqueueDownloads(toDownload);
  }

  Future<void> _addSelectedToAlbum(List<GalleryEntry> flat) async {
    final selected = _selectedEntries(flat);
    if (selected.isEmpty) return;

    final fileIds = <String>[];
    String? uploadError;
    for (final entry in selected) {
      if (entry.fileItem != null) {
        fileIds.add(entry.fileItem!.id);
        continue;
      }
      // Device-only entries are auto-uploaded first — a vault album can only
      // reference cloud files.
      try {
        final uploadedItem = await AssetUploadService.instance.uploadAndLink(
          ref,
          entry.asset!,
        );
        fileIds.add(uploadedItem.id);
      } catch (e) {
        uploadError = e.toString();
      }
    }
    if (fileIds.isNotEmpty) bumpDeviceState(ref);
    _exitSelection();

    if (fileIds.isEmpty) {
      if (uploadError != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload failed: $uploadError')));
      }
      return;
    }
    if (!mounted) return;
    await addFileIdsToAlbum(context, ref, fileIds);
    if (uploadError != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Some items could not be uploaded: $uploadError'),
        ),
      );
    }
  }

  void _archiveSelected(List<GalleryEntry> flat) {
    final ids = _selectedEntries(
      flat,
    ).where((e) => e.fileItem != null).map((e) => e.fileItem!.id).toList();
    _exitSelection();
    if (ids.isNotEmpty) ref.read(indexProvider.notifier).archiveFiles(ids);
  }

  Future<void> _deleteSelected(List<GalleryEntry> flat) async {
    final selected = _selectedEntries(flat);
    if (selected.isEmpty) return;

    final anyOnDevice = selected.any((e) => e.isOnDevice);
    final anyInCloud = selected.any((e) => e.isUploaded);
    final source = await askDeleteSource(
      context,
      existsOnDevice: anyOnDevice,
      existsInCloud: anyInCloud,
    );
    if (source == null) return;

    if (source == DeleteSource.cloud || source == DeleteSource.both) {
      final cloudItems = selected
          .where((e) => e.fileItem != null)
          .map((e) => e.fileItem!)
          .toList();
      if (cloudItems.isNotEmpty)
        await ref.read(indexProvider.notifier).deleteFiles(cloudItems);
    }
    if (source == DeleteSource.device || source == DeleteSource.both) {
      final assetIds = selected
          .where((e) => e.asset != null)
          .map((e) => e.asset!.id)
          .toList();
      if (assetIds.isNotEmpty) {
        final deleted = await PhotoManager.editor.deleteWithIds(assetIds);
        await PhotoManager.clearFileCache();
        if (deleted.length < assetIds.length && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Some items weren't deleted — Android's own confirmation wasn't approved.",
              ),
            ),
          );
        }
      }
    }
    bumpDeviceState(ref);
    _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(galleryFeedProvider);
    final groupsAsync = ref.watch(galleryMonthGroupsProvider);
    final flat = feedAsync.valueOrNull ?? const <GalleryEntry>[];
    _flat = flat;

    ref.listen(scrollToTopProvider, (prev, next) {
      if (next != null && next.tabIndex == 0) _scrollToTop();
    });
    ref.listen(downloadProvider, (prev, next) {
      final msg =
          next.savedMessage ??
          (next.error != null ? 'Failed: ${next.error}' : null);
      if (msg != null &&
          (next.savedMessage != prev?.savedMessage ||
              next.error != prev?.error)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    });
    ref.listen(indexProvider, (prev, next) {
      if (next.mutationError != null &&
          next.mutationError != prev?.mutationError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: ${next.mutationError}')),
        );
      }
    });

    return Scaffold(
      appBar: _selecting
          ? _SelectionAppBar(
              selection: _selection,
              flat: flat,
              onExit: _exitSelection,
              onShare: () => _shareSelected(flat),
              onUpload: () => _uploadSelected(flat),
              onDownload: () => _downloadSelected(flat),
              onAddToAlbum: () => _addSelectedToAlbum(flat),
              onArchive: () => _archiveSelected(flat),
              onDelete: () => _deleteSelected(flat),
            )
          : null,
      body: Stack(
        children: [
          _body(context, groupsAsync, flat),
          if (!_selecting) const FloatingProfileHeader(title: 'Gallery'),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncValue<List<GalleryMonthGroup>> groupsAsync,
    List<GalleryEntry> flat,
  ) {
    return groupsAsync.when(
      // Keep showing the current grid while the feed recomputes (e.g. after
      // each upload batch) instead of flashing a full-screen spinner.
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          'Could not load gallery: $e',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        ),
      ),
      data: (groups) {
        if (groups.isEmpty) {
          return const Center(
            child: Text(
              'No photos or videos yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        final topInset = _selecting
            ? 2.0
            : MediaQuery.of(context).padding.top + kToolbarHeight + 8;

        final slivers = _slivers(context, groups, flat, topInset);

        return NotificationListener<ScrollNotification>(
          onNotification: handleGalleryScroll,
          child: FastScrollbar(
            controller: _scrollController,
            topInset: topInset,
            bottomInset: 12,
            // An estimate: it maps scroll fraction straight onto the flat
            // entry list, which ignores the extra height month headers add.
            // Good enough to aim at a month while scrubbing, and far cheaper
            // than measuring real sliver geometry on every drag frame.
            labelForFraction: (f) {
              if (flat.isEmpty) return null;
              final i = (f * (flat.length - 1)).round().clamp(
                0,
                flat.length - 1,
              );
              return monthLabel(flat[i].effectiveDate.toLocal());
            },
            child: RefreshIndicator(
              onRefresh: () async {
                ThumbPrefetcher.instance.retryFailedNow();
                GalleryFeedService.instance.invalidateCache();
                ref.invalidate(galleryFeedProvider);
                await ref.read(galleryFeedProvider.future);
              },
              // Builds tiles ~2 screens ahead of the viewport so their
              // thumbnail requests start before they're actually visible,
              // instead of popping in right at the edge of the screen.
              child: CustomScrollView(
                // Survives a rebuild of this subtree with its offset intact.
                // Every completed upload recomputes the feed and rebuilds
                // every sliver here; without a storage key a rebuild that
                // recreates the Scrollable starts back at offset zero, which
                // is what threw the grid to the top mid-upload.
                key: const PageStorageKey<String>('gallery-timeline'),
                controller: _scrollController,
                scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
                slivers: slivers,
              ),
            ),
          ),
        );
      },
    );
  }

  /// The grid's slivers. Rebuilt only when the groups list, the flat list, the
  /// top inset or the permission banner changes: a screen rebuild for any other
  /// reason (selection mode, permission state) reuses the same widget instances,
  /// which Flutter skips, instead of re-running every visible tile's builder.
  ///
  /// When the feed did change, each month's slivers are reused as long as its
  /// [GalleryMonthGroup] instance is (see [groupEntriesByMonth]), and each
  /// tile widget as long as its [GalleryEntry] instance is (see [adoptFeed]):
  /// an upload batch then rebuilds only the tiles that gained a cloud badge,
  /// not every tile on screen.
  List<Widget> _slivers(
    BuildContext context,
    List<GalleryMonthGroup> groups,
    List<GalleryEntry> flat,
    double topInset,
  ) {
    final banner = Platform.isAndroid && _hasDeviceAccess == false;
    final cached = _sliverCache;
    if (cached != null &&
        identical(_cachedGroups, groups) &&
        identical(_cachedFlat, flat) &&
        _cachedTopInset == topInset &&
        _cachedBanner == banner) {
      return cached;
    }
    TvStats.screenBuild('gallery-slivers');
    final slivers = <Widget>[
      SliverToBoxAdapter(child: SizedBox(height: topInset)),
      if (banner) SliverToBoxAdapter(child: _permissionBanner()),
      for (final group in groups)
        ...(_groupSlivers[group] ??= _monthSlivers(group)),
    ];
    _cachedGroups = groups;
    _cachedFlat = flat;
    _cachedTopInset = topInset;
    _cachedBanner = banner;
    return _sliverCache = slivers;
  }

  /// Header and grid of one month section, cached in [_groupSlivers] for as
  /// long as [group] is the current instance of that month.
  List<Widget> _monthSlivers(GalleryMonthGroup group) {
    TvStats.screenBuild('gallery-month');
    // Captured per group so findChildIndexCallback below closes over
    // the right list. The lookup map is built at most once per group
    // instance, and only if the sliver actually asks — a linear
    // scan per child would be O(children × entries) on every upload.
    final entries = group.entries;
    Map<String, int>? indexByKey;
    return [
      // Keyed by month so a feed rebuild re-attaches each sliver to the same
      // month rather than to whatever now sits at that position. Without
      // keys, one new month at the top shifts every sliver by two and the
      // framework matches them by position.
      SliverPadding(
        key: ValueKey('header-${group.month.toIso8601String()}'),
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 10),
        sliver: SliverToBoxAdapter(
          child: Text(
            monthHeaderLabel(group.month, DateTime.now().year),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      SliverPadding(
        key: ValueKey('grid-${group.month.toIso8601String()}'),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 120,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _tile(entries[i]),
            childCount: entries.length,
            // New photos land at the FRONT of the newest month, so
            // every already-built tile shifts index on each upload.
            // Without this the sliver can't match a keyed child to its
            // new index, so it throws the element away and rebuilds it
            // from scratch — which is what made an upload land as a
            // visible lurch in the grid instead of a quiet insert.
            findChildIndexCallback: (Key key) {
              if (key is! ValueKey<String>) return null;
              final map = indexByKey ??= {
                for (var i = 0; i < entries.length; i++) entries[i].key: i,
              };
              return map[key.value];
            },
          ),
        ),
      ),
    ];
  }

  /// The tile of [entry], one widget instance per entry instance: a month
  /// grid rebuilt because another of its entries changed hands Flutter the
  /// identical widget for this one, which it skips.
  Widget _tile(GalleryEntry entry) => _tiles[entry] ??= SelectionScopedTile(
    key: ValueKey(entry.key),
    entry: entry,
    selection: _selection,
    onLongPress: () =>
        _selection.value.isNotEmpty ? _toggle(entry) : _startSelection(entry),
    onTap: () => _open(entry),
  );

  void _open(GalleryEntry entry) {
    if (_selection.value.isNotEmpty) {
      _toggle(entry);
      return;
    }
    // Looked up at tap time: the cached tile outlives feed rebuilds that
    // shift its position in the flat list.
    final flat = _flat;
    var index = flat.indexOf(entry);
    if (index < 0) index = flat.indexWhere((e) => e.key == entry.key);
    if (index < 0) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MixedMediaViewerScreen(entries: flat, initialIndex: index),
      ),
    );
  }

  Widget _permissionBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.photo_library_outlined,
            color: Color(0xFF2AABEE),
            size: 20,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Show photos from this device too, not just what\'s uploaded.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          TextButton(onPressed: _grantDeviceAccess, child: const Text('Allow')),
        ],
      ),
    );
  }
}

/// App bar of selection mode. Listens to [selection] itself so the count and
/// the enabled actions follow it without the screen rebuilding.
class _SelectionAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SelectionAppBar({
    required this.selection,
    required this.flat,
    required this.onExit,
    required this.onShare,
    required this.onUpload,
    required this.onDownload,
    required this.onAddToAlbum,
    required this.onArchive,
    required this.onDelete,
  });

  final ValueListenable<Set<String>> selection;
  final List<GalleryEntry> flat;
  final VoidCallback onExit;
  final VoidCallback onShare;
  final VoidCallback onUpload;
  final VoidCallback onDownload;
  final VoidCallback onAddToAlbum;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Set<String>>(
      valueListenable: selection,
      builder: (context, selected, _) {
        var needsUpload = false;
        var needsDownload = false;
        // Only cloud-backed entries can be archived — see FileItem.archived.
        var canArchive = false;
        for (final e in flat) {
          if (!selected.contains(e.key)) continue;
          if (e.fileItem == null) {
            needsUpload = true;
          } else {
            canArchive = true;
            if (e.asset == null) needsDownload = true;
          }
        }
        return AppBar(
          leading: IconButton(icon: const Icon(Icons.close), onPressed: onExit),
          title: Text('${selected.length} selected'),
          actions: [
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: 'Share',
              onPressed: onShare,
            ),
            IconButton(
              icon: const Icon(Icons.cloud_upload_outlined),
              tooltip: 'Upload',
              onPressed: needsUpload ? onUpload : null,
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Download',
              onPressed: needsDownload ? onDownload : null,
            ),
            IconButton(
              icon: const Icon(Icons.playlist_add),
              tooltip: 'Add to album',
              onPressed: onAddToAlbum,
            ),
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              tooltip: 'Archive',
              onPressed: canArchive ? onArchive : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: onDelete,
            ),
          ],
        );
      },
    );
  }
}
