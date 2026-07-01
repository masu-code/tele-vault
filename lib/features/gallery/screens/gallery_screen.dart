import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../download/providers/download_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../explorer/widgets/save_to_device_button.dart';
import '../../preview/screens/media_viewer_screen.dart';
import '../../../models/file_item.dart';
import '../widgets/gallery_tile.dart';

/// Google Photos-style grid of all media. Tap opens the full-screen viewer;
/// long-press (or right-click) starts multi-select, with delete and add-to-album
/// actions in the app bar.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  final Set<String> _selected = {};
  final Set<String> _savedIds = {}; // selected items already on the device
  bool _selecting = false;

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
        _savedIds.clear();
      });

  /// Caches whether [file] is already saved on the device, for the smart action.
  Future<void> _checkSaved(FileItem file) async {
    if (await LocalFileService.instance.isSaved(file)) {
      if (mounted) setState(() => _savedIds.add(file.id));
    }
  }

  void _toggle(FileItem file) {
    setState(() {
      if (_selected.contains(file.id)) {
        _selected.remove(file.id);
        _savedIds.remove(file.id);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(file.id);
      }
    });
    if (_selected.contains(file.id)) _checkSaved(file);
  }

  void _startSelection(FileItem file) {
    setState(() {
      _selecting = true;
      _selected.add(file.id);
    });
    _checkSaved(file);
  }

  Future<void> _deleteSelected(List<FileItem> media) async {
    final items = media.where((f) => _selected.contains(f.id)).toList();
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${items.length} item(s)?'),
        content: const Text(
          'This permanently removes the files from Telegram and frees the space. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(indexProvider.notifier).deleteFiles(items);
    _exitSelection();
  }

  Future<void> _saveSelected(List<FileItem> media) async {
    final items = media.where((f) => _selected.contains(f.id)).toList();
    if (items.isEmpty) return;
    _exitSelection();
    await ref.read(downloadProvider.notifier).saveManyToDevice(items);
  }

  Future<void> _addSelectedToAlbum() async {
    final albums = ref.read(indexProvider).index.albums;
    final fileIds = _selected.toList();
    if (fileIds.isEmpty) return;

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
                subtitle: Text('${a.fileIds.length} item(s)'),
                onTap: () => Navigator.pop(ctx, a.id),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;

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
    _exitSelection();
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
    final state = ref.watch(indexProvider);
    final media = state.index.mediaFiles;

    ref.listen(downloadProvider, (prev, next) {
      final msg = next.savedMessage ?? (next.error != null ? 'Failed: ${next.error}' : null);
      if (msg != null && (next.savedMessage != prev?.savedMessage || next.error != prev?.error)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    });

    final allSaved =
        _selected.isNotEmpty && _selected.every((id) => _savedIds.contains(id));

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelection),
              title: Text('${_selected.length} selected'),
              actions: [
                // All selected already on device -> a plain indicator.
                // Anything missing -> Download.
                if (allSaved)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: Icon(onDeviceIcon(), color: const Color(0xFF2AABEE)),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.download_outlined),
                    tooltip: 'Save to device',
                    onPressed: () => _saveSelected(media),
                  ),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Add to album',
                  onPressed: _addSelectedToAlbum,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () => _deleteSelected(media),
                ),
              ],
            )
          : AppBar(title: const Text('Gallery')),
      body: _body(state, media),
    );
  }

  Widget _body(IndexState state, List<FileItem> media) {
    if (state.isLoading && media.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (media.isEmpty) {
      return const Center(
        child: Text(
          'No photos or videos yet.\nUpload some from the Files tab.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: media.length,
      itemBuilder: (context, i) {
        final file = media[i];
        return GalleryTile(
          key: ValueKey(file.id),
          file: file,
          selected: _selected.contains(file.id),
          onLongPress: () => _selecting ? _toggle(file) : _startSelection(file),
          onTap: () {
            if (_selecting) {
              _toggle(file);
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MediaViewerScreen(items: media, initialIndex: i),
                ),
              );
            }
          },
        );
      },
    );
  }
}
