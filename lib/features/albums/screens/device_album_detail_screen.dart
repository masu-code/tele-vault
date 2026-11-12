import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/backup/asset_upload_service.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/upload/upload_service.dart' show assetTakenAtMs;
import '../../backup/providers/backup_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../explorer/widgets/save_to_device_button.dart';
import '../../gallery/widgets/scroll_idle.dart';
import '../../preview/widgets/delete_source_dialog.dart';
import '../../transfer/providers/transfer_queue_provider.dart';
import 'device_asset_viewer_screen.dart';

/// Detail view for a device media album. Shows all photos/videos from the
/// device and lets the user toggle backup for this album, or long-press to
/// select a few photos and upload just those.
class DeviceAlbumDetailScreen extends ConsumerStatefulWidget {
  const DeviceAlbumDetailScreen({super.key, required this.album});

  final AssetPathEntity album;

  @override
  ConsumerState<DeviceAlbumDetailScreen> createState() =>
      _DeviceAlbumDetailScreenState();
}

class _DeviceAlbumDetailScreenState
    extends ConsumerState<DeviceAlbumDetailScreen> {
  /// Assets loaded so far, newest first. The album can hold thousands, so it
  /// is read a page at a time as the user scrolls (see [_loadMore]).
  List<AssetEntity> _assets = [];

  /// Asset count reported by the platform at the last (re)load.
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// Bumped by every reload so an older in-flight page can't clobber newer data.
  int _gen = 0;

  static const _pageSize = 300;
  final ScrollController _scroll = ScrollController();

  final Set<String> _selected = {};
  bool _selecting = false;
  int? _uploadTotal;
  int _uploadDone = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadAssets();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 1500) _loadMore();
  }

  Future<void> _loadAssets() async {
    final gen = ++_gen;
    try {
      final count = await widget.album.assetCountAsync;
      final assets = count == 0
          ? <AssetEntity>[]
          : await widget.album.getAssetListRange(
              start: 0, end: math.min(count, _pageSize));
      if (!mounted || gen != _gen) return;
      setState(() {
        _assets = assets;
        _total = count;
        _loading = false;
      });
    } catch (e) {
      // The album can go stale after its last asset was deleted on the
      // device (e.g. via "free up storage") — don't spin forever.
      if (mounted && gen == _gen) {
        setState(() { _error = e.toString(); _loading = false; });
      }
    }
  }

  /// Appends the next page. Reads from the current length (not a page index)
  /// so it stays correct after assets were removed locally.
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _assets.length >= _total) return;
    _loadingMore = true;
    final gen = _gen;
    try {
      final start = _assets.length;
      final more = await widget.album.getAssetListRange(
          start: start, end: math.min(_total, start + _pageSize));
      if (!mounted || gen != _gen || more.isEmpty) return;
      setState(() => _assets = [..._assets, ...more]);
    } catch (_) {
      // Keep what is already shown; the next scroll retries.
    } finally {
      _loadingMore = false;
    }
  }

  /// Re-fetches the asset list without toggling the full-screen loading
  /// spinner. Unless [force] (pull-to-refresh), it only reloads when the
  /// platform's asset count changed: device-state bumps fire for every
  /// upload/delete anywhere in the app, and most don't touch this album.
  Future<void> _refreshAssetsQuietly({bool force = false}) async {
    try {
      final count = await widget.album.assetCountAsync;
      if (!mounted) return;
      if (!force && count == _total) {
        // Same asset count, but a backup may have finished: rebuild so the
        // "backed up" badges and the selection bar's allUploaded refresh,
        // without rescanning assets.
        setState(() {});
        return;
      }
      // Keep as many assets loaded as before (all of them if the user had
      // already scrolled through the whole album, so new ones show up).
      final allLoaded = _assets.length >= _total;
      final want = count == 0
          ? 0
          : allLoaded
              ? count
              : math.min(count, math.max(_assets.length, _pageSize));
      final gen = ++_gen;
      final assets = want == 0
          ? <AssetEntity>[]
          : await widget.album.getAssetListRange(start: 0, end: want);
      if (!mounted || gen != _gen) return;
      setState(() {
        _assets = assets;
        _total = count;
      });
    } catch (_) {
      // Ignore — the album itself may have gone stale; the existing list
      // stays as-is rather than flashing an error for a background refresh.
    }
  }

  void _startSelection(String assetId) {
    setState(() {
      _selecting = true;
      _selected.add(assetId);
    });
  }

  void _toggle(String assetId) {
    setState(() {
      if (_selected.remove(assetId)) {
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(assetId);
      }
    });
  }

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _shareSelected() async {
    final chosen = _assets.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    _exitSelection();
    try {
      final files = await Future.wait(chosen.map((a) => a.file));
      final paths = files.whereType<File>().map((f) => XFile(f.path)).toList();
      if (paths.isEmpty) return;
      await SharePlus.instance.share(ShareParams(files: paths));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
      }
    }
  }

  Future<void> _deleteSelected() async {
    final chosen = _assets.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    _exitSelection();

    final registry = BackupRegistry.instance;
    final anyUploaded = chosen.any((a) => registry.isUploaded(a.id));
    final source = await askDeleteSource(context, existsOnDevice: true, existsInCloud: anyUploaded);
    if (source == null || !mounted) return;

    try {
      var deletedIds = <String>[];
      if (source == DeleteSource.device || source == DeleteSource.both) {
        // Android shows its own confirmation popup for media this app didn't
        // create — declining it (or missing it) means nothing gets deleted.
        deletedIds = await PhotoManager.editor.deleteWithIds(chosen.map((a) => a.id).toList());
        if (deletedIds.isNotEmpty) {
          await PhotoManager.clearFileCache();
          if (mounted) {
            setState(() {
              _assets.removeWhere((a) => deletedIds.contains(a.id));
              _total = math.max(0, _total - deletedIds.length);
            });
          }
          await ref.read(backupProvider.notifier).refreshDeviceAlbums();
        }
      }
      if (source == DeleteSource.cloud || source == DeleteSource.both) {
        final fileItems = [
          for (final a in chosen)
            for (final f in ref.read(indexProvider).index.files)
              if (f.id == registry.fileItemIdFor(a.id)) f,
        ];
        if (fileItems.isNotEmpty) await ref.read(indexProvider.notifier).deleteFiles(fileItems);
      }
      bumpDeviceState(ref);

      if (!mounted) return;
      if (source == DeleteSource.device && deletedIds.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Delete cancelled — Android's own confirmation wasn't approved."),
        ));
        return;
      }
      final skipped = source != DeleteSource.cloud ? chosen.length - deletedIds.length : 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(skipped > 0
            ? 'Deleted ${chosen.length - skipped} item(s); $skipped cancelled'
            : 'Deleted ${chosen.length} item(s)'),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      }
    }
  }

  void _uploadSelected() {
    final chosen = _assets.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    _exitSelection();
    // Hand off to the global queue — it batches index writes and reports
    // progress in the banner, instead of blocking here with a per-file loop
    // that hammered the index and froze the UI on large selections.
    ref.read(transferQueueProvider.notifier).enqueueUploads(chosen);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Uploading ${chosen.length} item(s)…')),
    );
  }

  /// Adds the selected device photos to a vault album. Vault albums are keyed
  /// by cloud file id, not device asset id, so anything not already uploaded
  /// is uploaded first (reusing the link if it's uploaded already).
  Future<void> _addSelectedToAlbum() async {
    final chosen = _assets.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    _exitSelection();

    final index = ref.read(indexProvider).index;
    final albums = index.albums;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New album…'),
              onTap: () => Navigator.pop(ctx, '__new__'),
            ),
            if (albums.isNotEmpty) const Divider(height: 1),
            for (final a in albums)
              ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: Text(a.name),
                // filesByIds skips ids that no longer resolve to a file — the
                // count should reflect what's actually shown, not the raw
                // (possibly stale) fileIds list length.
                subtitle: Text('${index.filesByIds(a.fileIds).length} item(s)'),
                onTap: () => Navigator.pop(ctx, a.id),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    setState(() { _uploadTotal = chosen.length; _uploadDone = 0; });
    final registry = BackupRegistry.instance;
    final fileIds = <String>[];

    for (final asset in chosen) {
      try {
        var fileItemId = registry.fileItemIdFor(asset.id);
        if (fileItemId == null) {
          final file = await asset.originFile;
          if (file != null) {
            // Pending-index row, then an index save that throws on failure:
            // the asset is linked (and marked uploaded) only once its file
            // is in the written index.
            final fileItem = await AssetUploadService.instance
                .uploadAndLinkFile(ref, asset.id, file,
                    takenAtMs: assetTakenAtMs(asset));
            fileItemId = fileItem.id;
          }
        }
        if (fileItemId != null) fileIds.add(fileItemId);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to upload ${asset.title}: $e')),
          );
        }
      }
      if (mounted) setState(() => _uploadDone++);
    }

    bumpDeviceState(ref);
    if (mounted) setState(() => _uploadTotal = null);
    if (fileIds.isEmpty) return;

    if (choice == '__new__') {
      final name = await _promptAlbumName();
      if (name == null || name.isEmpty) return;
      await ref.read(indexProvider.notifier).createAlbum(name, fileIds: fileIds);
    } else {
      await ref.read(indexProvider.notifier).addToAlbum(choice, fileIds);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${fileIds.length} item(s) to album')),
      );
    }
  }

  Future<String?> _promptAlbumName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New album'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Album name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Any upload/delete anywhere in the app (not just via this screen) can
    // change what belongs in this album — keep it in sync live.
    ref.listen(deviceStateVersion, (prev, next) {
      if (prev != next) _refreshAssetsQuietly();
    });
    ref.listen(indexProvider.select((s) => s.mutationError), (prev, next) {
      if (next != null && next != prev) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: $next')),
        );
      }
    });
    // Only this album's flag; sync progress ticks live in [_BackupBanner].
    final albumId = widget.album.id;
    final isEnabled =
        ref.watch(backupProvider.select((s) => s.isEnabled(albumId)));
    final registry = BackupRegistry.instance;
    var allUploaded = false;
    if (_selecting) {
      final selectedAssets =
          _assets.where((a) => _selected.contains(a.id)).toList();
      allUploaded = selectedAssets.isNotEmpty &&
          selectedAssets.every((a) => registry.isUploaded(a.id));
    }

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelection),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Share',
                  onPressed: _shareSelected,
                ),
                // Cloud-backup status: Upload (pending) or Uploaded (done).
                if (allUploaded)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: Icon(Icons.cloud_done_outlined, color: Color(0xFF2AABEE)),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.cloud_upload_outlined),
                    tooltip: 'Upload',
                    onPressed: _uploadSelected,
                  ),
                // Device-presence status: always on device here — informational.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Icon(onDeviceIcon(), color: const Color(0xFF2AABEE)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add to album',
                  onPressed: _addSelectedToAlbum,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  tooltip: 'Delete from device',
                  onPressed: _deleteSelected,
                ),
              ],
            )
          : AppBar(
              title: Text(widget.album.name),
              actions: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_outlined,
                        size: 18,
                        color: isEnabled ? const Color(0xFF2AABEE) : Colors.white38,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Backup',
                        style: TextStyle(
                          color: isEnabled ? const Color(0xFF2AABEE) : Colors.white70,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Switch(
                        value: isEnabled,
                        onChanged: (_) =>
                            ref.read(backupProvider.notifier).toggleBackup(widget.album),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      body: Column(
        children: [
          _BackupBanner(albumId: albumId),
          if (_uploadTotal != null)
            _SyncBanner(done: _uploadDone, total: _uploadTotal!),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'This album is empty or no longer available on the device.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54),
                          ),
                        ),
                      )
                    : _assets.isEmpty
                    ? RefreshIndicator(
                        onRefresh: () => _refreshAssetsQuietly(force: true),
                        child: ListView(
                          children: const [
                            Padding(
                              padding: EdgeInsets.only(top: 120),
                              child: Center(
                                child: Text('No photos or videos in this album.',
                                    style: TextStyle(color: Colors.white54)),
                              ),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _refreshAssetsQuietly(force: true),
                        child: ScrollIdleTracker(
                          child: GridView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(2),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 120,
                              crossAxisSpacing: 2,
                              mainAxisSpacing: 2,
                            ),
                            itemCount: _assets.length,
                            itemBuilder: (context, i) {
                              final asset = _assets[i];
                              return _AssetTile(
                                key: ValueKey(asset.id),
                                asset: asset,
                                backed: isEnabled && registry.isUploaded(asset.id),
                                selected: _selected.contains(asset.id),
                                onTap: () {
                                  if (_selecting) {
                                    _toggle(asset.id);
                                  } else {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => DeviceAssetViewerScreen(
                                          assets: _assets,
                                          initialIndex: i,
                                        ),
                                      ),
                                      // The viewer may have deleted this asset — refresh so
                                      // the grid doesn't keep showing (and crash opening) it.
                                    ).then((_) => _refreshAssetsQuietly());
                                  }
                                },
                                onLongPress: () => _selecting
                                    ? _toggle(asset.id)
                                    : _startSelection(asset.id),
                              );
                            },
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

/// Sync-progress banner for this album. A leaf widget so per-file progress
/// ticks rebuild only the banner, not the whole screen and grid.
class _BackupBanner extends ConsumerWidget {
  const _BackupBanner({required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress =
        ref.watch(backupProvider.select((s) => s.progressFor(albumId)));
    if (progress == null || progress.isDone || progress.isIdle) {
      return const SizedBox.shrink();
    }
    return _SyncBanner(
      done: progress.done,
      total: progress.total,
      currentName: progress.currentName,
    );
  }
}

class _SyncBanner extends StatelessWidget {
  const _SyncBanner({
    required this.done,
    required this.total,
    this.currentName,
  });

  final int done;
  final int total;
  final String? currentName;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF14303F),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              currentName != null
                  ? 'Uploading $done/$total: $currentName'
                  : 'Uploading $done/$total…',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: total == 0 ? null : done / total),
          ],
        ),
      ),
    );
  }
}

/// A single asset thumbnail tile. Shows a cloud checkmark overlay when the
/// asset has already been backed up, or a selection checkmark in select mode.
class _AssetTile extends StatefulWidget {
  const _AssetTile({
    super.key,
    required this.asset,
    required this.backed,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final AssetEntity asset;
  final bool backed;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_AssetTile> createState() => _AssetTileState();
}

class _AssetTileState extends State<_AssetTile> {
  Uint8List? _thumb;
  bool _loading = false;
  ValueListenable<bool>? _scrollIdle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Same gating as GalleryTile: no thumbnail request while the grid is
    // moving, so a fast fling doesn't queue a platform-channel read for every
    // tile that flashes past.
    final idle = ScrollIdle.maybeOf(context);
    if (idle != _scrollIdle) {
      _scrollIdle?.removeListener(_maybeLoad);
      _scrollIdle = idle;
      _scrollIdle?.addListener(_maybeLoad);
    }
    _maybeLoad();
  }

  @override
  void didUpdateWidget(_AssetTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled tile for another asset must not keep the old thumbnail.
    if (oldWidget.asset.id != widget.asset.id) {
      _thumb = null;
      _loading = false;
      _maybeLoad();
    }
  }

  @override
  void dispose() {
    _scrollIdle?.removeListener(_maybeLoad);
    super.dispose();
  }

  void _maybeLoad() {
    if (_thumb != null || _loading) return;
    if (_scrollIdle?.value == false) return;
    _loadThumb();
  }

  Future<void> _loadThumb() async {
    _loading = true;
    final asset = widget.asset;
    try {
      final data = await asset.thumbnailDataWithSize(
        const ThumbnailSize(200, 200),
      );
      if (mounted && data != null && asset.id == widget.asset.id) {
        setState(() => _thumb = data);
      }
    } catch (_) {
      // The asset may have just been deleted from the device — keep showing
      // the placeholder instead of an unhandled exception.
    } finally {
      if (asset.id == widget.asset.id) _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.asset.type == AssetType.video;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onLongPress,
      child: Container(
        color: const Color(0xFF1C1C1E),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_thumb != null)
              Image.memory(
                _thumb!,
                fit: BoxFit.cover,
                cacheWidth: 300,
                gaplessPlayback: true,
              )
            else
              Center(
                child: Icon(
                  isVideo ? Icons.movie_outlined : Icons.image_outlined,
                  color: Colors.white30,
                ),
              ),
            if (isVideo && !widget.selected)
              const Align(
                child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 28),
              ),
            if (widget.backed && !widget.selected)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(Icons.cloud_done,
                      color: Color(0xFF2AABEE), size: 16),
                ),
              ),
            if (widget.selected) ...[
              Container(color: const Color(0x662AABEE)),
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.check_circle, color: Color(0xFF2AABEE), size: 22),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
