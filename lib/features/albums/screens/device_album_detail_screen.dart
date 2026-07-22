import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/backup/device_state_bus.dart';
import '../../../core/upload/upload_service.dart';
import '../../backup/providers/backup_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../explorer/widgets/save_to_device_button.dart';
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
  List<AssetEntity> _assets = [];
  bool _loading = true;
  String? _error;

  final Set<String> _selected = {};
  bool _selecting = false;
  int? _uploadTotal;
  int _uploadDone = 0;

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    try {
      final count = await widget.album.assetCountAsync;
      final assets =
          count == 0 ? <AssetEntity>[] : await widget.album.getAssetListRange(start: 0, end: count);
      if (mounted) setState(() { _assets = assets; _loading = false; });
    } catch (e) {
      // The album can go stale after its last asset was deleted on the
      // device (e.g. via "free up storage") — don't spin forever.
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  /// Re-fetches the asset list without toggling the full-screen loading
  /// spinner — used after returning from the viewer, which may have deleted
  /// the asset being viewed.
  Future<void> _refreshAssetsQuietly() async {
    try {
      // photo_manager can otherwise keep answering with pre-mutation counts
      // for a moment right after a delete/upload.
      await PhotoManager.clearFileCache();
      final count = await widget.album.assetCountAsync;
      final assets =
          count == 0 ? <AssetEntity>[] : await widget.album.getAssetListRange(start: 0, end: count);
      if (mounted) setState(() => _assets = assets);
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
          if (mounted) setState(() => _assets.removeWhere((a) => deletedIds.contains(a.id)));
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
            final fileItem = await UploadService.instance.uploadFile(file);
            await ref.read(indexProvider.notifier).addFile(fileItem);
            await registry.markUploaded(asset.id);
            await registry.linkLocalPath(fileItem.id, file.path);
            await registry.linkFileItem(asset.id, fileItem.id);
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
    ref.listen(indexProvider, (prev, next) {
      if (next.mutationError != null && next.mutationError != prev?.mutationError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: ${next.mutationError}')),
        );
      }
    });
    final backup = ref.watch(backupProvider);
    final isEnabled = backup.isEnabled(widget.album.id);
    final progress = backup.progressFor(widget.album.id);
    final registry = BackupRegistry.instance;
    final selectedAssets = _assets.where((a) => _selected.contains(a.id));
    final allUploaded = selectedAssets.isNotEmpty && selectedAssets.every((a) => registry.isUploaded(a.id));

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
          if (progress != null && !progress.isDone && !progress.isIdle)
            _SyncBanner(
              done: progress.done,
              total: progress.total,
              currentName: progress.currentName,
            ),
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
                        onRefresh: _refreshAssetsQuietly,
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
                        onRefresh: _refreshAssetsQuietly,
                        child: GridView.builder(
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
                              asset: asset,
                              backed: isEnabled &&
                                  BackupRegistry.instance.isUploaded(asset.id),
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
        ],
      ),
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

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  Future<void> _loadThumb() async {
    try {
      final data = await widget.asset.thumbnailDataWithSize(
        const ThumbnailSize(200, 200),
      );
      if (mounted && data != null) setState(() => _thumb = data);
    } catch (_) {
      // The asset may have just been deleted from the device — keep showing
      // the placeholder instead of an unhandled exception.
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
              Image.memory(_thumb!, fit: BoxFit.cover)
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
