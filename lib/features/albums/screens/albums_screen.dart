import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../../core/diag/tv_stats.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../../../models/album.dart';
import '../../../models/file_item.dart';
import '../../backup/providers/backup_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../providers/vault_album_summaries.dart';
import '../../profile/widgets/floating_profile_header.dart';
import '../../shell/scroll_to_top.dart';
import 'album_detail_screen.dart';
import 'device_album_detail_screen.dart';

/// Unified grid of albums: vault albums (manual, always in Telegram) and device
/// media albums (Android only). Cloud icon = content is in / being synced to
/// Telegram.
class AlbumsScreen extends ConsumerStatefulWidget {
  const AlbumsScreen({super.key});

  @override
  ConsumerState<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends ConsumerState<AlbumsScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(backupProvider.notifier).loadDeviceAlbums();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  // --- Vault album actions -----------------------------------------------

  Future<void> _createAlbum() async {
    final name = await _promptName('New album');
    if (name != null && name.isNotEmpty) {
      await ref.read(indexProvider.notifier).createAlbum(name);
    }
  }

  Future<void> _renameAlbum(Album album) async {
    final name = await _promptName('Rename album', initial: album.name);
    if (name != null && name.isNotEmpty) {
      await ref.read(indexProvider.notifier).renameAlbum(album.id, name);
    }
  }

  Future<void> _deleteAlbum(Album album) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${album.name}"?'),
        content: const Text(
            'The album is removed. The photos themselves stay in your vault.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await ref.read(indexProvider.notifier).removeAlbum(album.id);
  }

  Future<String?> _promptName(String title, {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Album name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _vaultAlbumMenu(Album album) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(ctx);
                _renameAlbum(album);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete album'),
              onTap: () {
                Navigator.pop(ctx);
                _deleteAlbum(album);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _deviceAlbumMenu(AssetPathEntity album) {
    final backup = ref.read(backupProvider);
    final isEnabled = backup.isEnabled(album.id);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isEnabled ? Icons.cloud_off_outlined : Icons.cloud_upload_outlined,
              ),
              title: Text(isEnabled ? 'Disable backup' : 'Enable backup'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(backupProvider.notifier).toggleBackup(album);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    TvStats.screenBuild('albums');
    ref.listen(scrollToTopProvider, (prev, next) {
      if (next != null && next.tabIndex == 1) _scrollToTop();
    });
    // Narrow watches: this tab is kept alive in the IndexedStack, so watching
    // whole providers rebuilt it on every upload/progress tick.
    final vaultAlbums = ref.watch(vaultAlbumSummariesProvider).items;
    final deviceAlbums = ref.watch(backupProvider.select((s) => s.deviceAlbums));
    final enabledIds = ref.watch(backupProvider.select((s) => s.enabledIds));
    final refreshTick = ref.watch(backupProvider.select((s) => s.refreshTick));

    final totalCount = vaultAlbums.length + deviceAlbums.length;

    final topInset = MediaQuery.of(context).padding.top + kToolbarHeight + 8;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createAlbum,
        icon: const Icon(Icons.add),
        label: const Text('New album'),
      ),
      body: Stack(
        children: [
          totalCount == 0
              ? Center(
                  child: Text(
                    Platform.isAndroid
                        ? 'No albums yet.\nCreate one or enable backup for a device album.'
                        : 'No albums yet.\nCreate one here or select photos in the Gallery.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54),
                  ),
                )
              : GridView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.fromLTRB(12, topInset, 12, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: totalCount,
                  itemBuilder: (context, i) {
                // Device albums come first.
                if (i < deviceAlbums.length) {
                  final album = deviceAlbums[i];
                  return _DeviceAlbumCard(
                    key: ValueKey('device_${album.id}'),
                    album: album,
                    hasCloud: enabledIds.contains(album.id),
                    refreshTick: refreshTick,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => DeviceAlbumDetailScreen(album: album),
                    )),
                    onLongPress: () => _deviceAlbumMenu(album),
                  );
                }
                // Vault albums follow.
                final summary = vaultAlbums[i - deviceAlbums.length];
                final album = summary.album;
                return _VaultAlbumCard(
                  key: ValueKey('vault_${album.id}'),
                  album: album,
                  itemCount: summary.itemCount,
                  cover: summary.cover,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => AlbumDetailScreen(albumId: album.id),
                  )),
                  onLongPress: () => _vaultAlbumMenu(album),
                );
                  },
                ),
          const FloatingProfileHeader(title: 'Albums'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Vault album card — cover from ThumbnailService; always has cloud icon.
// ---------------------------------------------------------------------------

class _VaultAlbumCard extends StatelessWidget {
  const _VaultAlbumCard({
    super.key,
    required this.album,
    required this.itemCount,
    required this.cover,
    required this.onTap,
    required this.onLongPress,
  });

  final Album album;
  // The number of files actually resolvable in the index — not
  // album.fileIds.length, which would overcount if the album still
  // references a file id that no longer exists (e.g. a stale index written
  // by an older app version that didn't clean up album membership on
  // delete).
  final int itemCount;
  final FileItem? cover;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  cover == null
                      ? Container(
                          color: const Color(0xFF1C1C1E),
                          child: const Center(
                            child: Icon(Icons.photo_album_outlined,
                                color: Colors.white30, size: 36),
                          ),
                        )
                      : _VaultCover(file: cover!),
                  // Cloud icon — always present for vault albums.
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.all(3),
                      child: const Icon(Icons.cloud,
                          color: Color(0xFF2AABEE), size: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          Text('$itemCount item(s)',
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ],
      ),
    );
  }
}

class _VaultCover extends StatefulWidget {
  const _VaultCover({required this.file});
  final FileItem file;

  @override
  State<_VaultCover> createState() => _VaultCoverState();
}

class _VaultCoverState extends State<_VaultCover> {
  File? _thumb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_VaultCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id) {
      setState(() => _thumb = null);
      _load();
    }
  }

  void _load() {
    ThumbnailService.instance
        .thumbnailFor(widget.file)
        .then((f) { if (mounted) setState(() => _thumb = f); });
  }

  @override
  Widget build(BuildContext context) {
    if (_thumb == null) return Container(color: const Color(0xFF1C1C1E));
    return Image.file(_thumb!, fit: BoxFit.cover, cacheWidth: 400,
        errorBuilder: (_, _, _) => Container(color: const Color(0xFF1C1C1E)));
  }
}

// ---------------------------------------------------------------------------
// Device album card — cover from photo_manager; cloud icon only when backed up.
// ---------------------------------------------------------------------------

class _DeviceAlbumCard extends StatefulWidget {
  const _DeviceAlbumCard({
    super.key,
    required this.album,
    required this.hasCloud,
    required this.onTap,
    required this.onLongPress,
    required this.refreshTick,
  });

  final AssetPathEntity album;
  final bool hasCloud;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// Bumped by [BackupNotifier.refreshDeviceAlbums] — forces this card to
  /// reload its cover/count even though the album's own id is unchanged.
  final int refreshTick;

  @override
  State<_DeviceAlbumCard> createState() => _DeviceAlbumCardState();
}

class _DeviceAlbumCardState extends State<_DeviceAlbumCard> {
  AssetEntity? _cover;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_DeviceAlbumCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.id != widget.album.id ||
        oldWidget.refreshTick != widget.refreshTick) {
      setState(() { _cover = null; _count = 0; });
      _load();
    }
  }

  Future<void> _load() async {
    final count = await widget.album.assetCountAsync;
    final assets = count > 0
        ? await widget.album.getAssetListRange(start: 0, end: 1)
        : <AssetEntity>[];
    if (mounted) setState(() { _count = count; _cover = assets.isNotEmpty ? assets.first : null; });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _cover == null
                      ? Container(
                          color: const Color(0xFF1C1C1E),
                          child: const Center(
                            child: Icon(Icons.photo_library_outlined,
                                color: Colors.white30, size: 36),
                          ),
                        )
                      : _DeviceCover(asset: _cover!),
                  if (widget.hasCloud)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.all(3),
                        child: const Icon(Icons.cloud,
                            color: Color(0xFF2AABEE), size: 14),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(widget.album.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          Text('$_count item(s)',
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ],
      ),
    );
  }
}

class _DeviceCover extends StatefulWidget {
  const _DeviceCover({required this.asset});
  final AssetEntity asset;

  @override
  State<_DeviceCover> createState() => _DeviceCoverState();
}

class _DeviceCoverState extends State<_DeviceCover> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_DeviceCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      setState(() => _thumb = null);
      _load();
    }
  }

  void _load() {
    widget.asset
        .thumbnailDataWithSize(const ThumbnailSize(300, 300))
        .then((bytes) {
      if (mounted && bytes != null) setState(() => _thumb = bytes);
    }).catchError((Object _) {
      // The asset may have just been deleted from the device.
    });
  }

  Uint8List? _thumb;

  @override
  Widget build(BuildContext context) {
    final bytes = _thumb;
    if (bytes == null || bytes.isEmpty) {
      return Container(color: const Color(0xFF1C1C1E));
    }
    // The same Uint8List instance on every build, so the image cache key is
    // stable and the cover isn't re-decoded when the card rebuilds.
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      cacheWidth: 300,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => Container(color: const Color(0xFF1C1C1E)),
    );
  }
}
