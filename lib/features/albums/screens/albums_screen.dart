import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../../../models/album.dart';
import '../../../models/file_item.dart';
import '../../explorer/providers/index_provider.dart';
import 'album_detail_screen.dart';

/// Grid of manual albums. Each shows the first item's thumbnail as a cover.
class AlbumsScreen extends ConsumerStatefulWidget {
  const AlbumsScreen({super.key});

  @override
  ConsumerState<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends ConsumerState<AlbumsScreen> {
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
        title: Text('Delete album "${album.name}"?'),
        content: const Text('The album is removed. The photos themselves stay in your vault.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await ref.read(indexProvider.notifier).removeAlbum(album.id);
  }

  Future<String?> _promptName(String title, {String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
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
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _albumMenu(Album album) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () { Navigator.pop(ctx); _renameAlbum(album); },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete album'),
              onTap: () { Navigator.pop(ctx); _deleteAlbum(album); },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(indexProvider).index;
    final albums = index.albums;

    return Scaffold(
      appBar: AppBar(title: const Text('Albums')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createAlbum,
        icon: const Icon(Icons.add),
        label: const Text('New album'),
      ),
      body: albums.isEmpty
          ? const Center(
              child: Text(
                'No albums yet.\nCreate one here, or select photos in the Gallery\nand "Add to album".',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.85,
              ),
              itemCount: albums.length,
              itemBuilder: (context, i) {
                final album = albums[i];
                final items = index.filesByIds(album.fileIds);
                final cover = items.isNotEmpty ? items.first : null;
                return _AlbumCard(
                  album: album,
                  cover: cover,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => AlbumDetailScreen(albumId: album.id)),
                  ),
                  onLongPress: () => _albumMenu(album),
                );
              },
            ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.cover,
    required this.onTap,
    required this.onLongPress,
  });

  final Album album;
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
              child: cover == null
                  ? Container(
                      color: const Color(0xFF1C1C1E),
                      child: const Center(
                        child: Icon(Icons.photo_album_outlined, color: Colors.white30, size: 36),
                      ),
                    )
                  : _Cover(file: cover!),
            ),
          ),
          const SizedBox(height: 6),
          Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500)),
          Text('${album.fileIds.length} item(s)',
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ],
      ),
    );
  }
}

class _Cover extends StatefulWidget {
  const _Cover({required this.file});
  final FileItem file;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  File? _thumb;

  @override
  void initState() {
    super.initState();
    ThumbnailService.instance.thumbnailFor(widget.file).then((f) {
      if (mounted) setState(() => _thumb = f);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_thumb == null) {
      return Container(color: const Color(0xFF1C1C1E));
    }
    return Image.file(_thumb!, fit: BoxFit.cover, cacheWidth: 400,
        errorBuilder: (_, _, _) => Container(color: const Color(0xFF1C1C1E)));
  }
}
