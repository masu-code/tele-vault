import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/backup/backup_registry.dart';
import '../../../core/upload/upload_service.dart';
import '../../backup/providers/backup_provider.dart';
import '../../explorer/providers/index_provider.dart';
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
    final count = await widget.album.assetCountAsync;
    final assets =
        await widget.album.getAssetListRange(start: 0, end: count);
    if (mounted) setState(() { _assets = assets; _loading = false; });
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

  Future<void> _uploadSelected() async {
    final chosen = _assets.where((a) => _selected.contains(a.id)).toList();
    if (chosen.isEmpty) return;
    _exitSelection();

    setState(() { _uploadTotal = chosen.length; _uploadDone = 0; });
    final registry = BackupRegistry.instance;

    for (final asset in chosen) {
      try {
        if (!registry.isUploaded(asset.id)) {
          final file = await asset.originFile;
          if (file != null) {
            final fileItem = await UploadService.instance.uploadFile(file);
            await ref.read(indexProvider.notifier).addFile(fileItem);
            await registry.markUploaded(asset.id);
            await registry.linkLocalPath(fileItem.id, file.path);
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to upload ${asset.title}: $e')),
          );
        }
      }
      if (mounted) setState(() => _uploadDone++);
    }

    if (mounted) {
      setState(() => _uploadTotal = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uploaded ${chosen.length} item(s)')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final backup = ref.watch(backupProvider);
    final isEnabled = backup.isEnabled(widget.album.id);
    final progress = backup.progressFor(widget.album.id);

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelection),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: 'Upload to cloud',
                  onPressed: _uploadSelected,
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
                : _assets.isEmpty
                    ? const Center(
                        child: Text('No photos or videos in this album.',
                            style: TextStyle(color: Colors.white54)),
                      )
                    : GridView.builder(
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
                                );
                              }
                            },
                            onLongPress: () => _selecting
                                ? _toggle(asset.id)
                                : _startSelection(asset.id),
                          );
                        },
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
    final data = await widget.asset.thumbnailDataWithSize(
      const ThumbnailSize(200, 200),
    );
    if (mounted && data != null) setState(() => _thumb = data);
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
