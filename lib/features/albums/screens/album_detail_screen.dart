import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../download/providers/download_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../explorer/widgets/save_to_device_button.dart';
import '../../gallery/widgets/gallery_tile.dart';
import '../../preview/screens/media_viewer_screen.dart';
import '../../../models/file_item.dart';

/// Shows one album's media. Tap opens the viewer; long-press selects items to
/// remove from the album (the files themselves are not deleted).
class AlbumDetailScreen extends ConsumerStatefulWidget {
  const AlbumDetailScreen({super.key, required this.albumId});

  final String albumId;

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  final Set<String> _selected = {};
  final Set<String> _savedIds = {};
  bool _selecting = false;

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
        _savedIds.clear();
      });

  Future<void> _checkSaved(FileItem file) async {
    if (await LocalFileService.instance.isSaved(file)) {
      if (mounted) setState(() => _savedIds.add(file.id));
    }
  }

  void _startSelection(FileItem f) {
    setState(() {
      _selecting = true;
      _selected.add(f.id);
    });
    _checkSaved(f);
  }

  void _toggle(FileItem f) {
    setState(() {
      if (_selected.remove(f.id)) {
        _savedIds.remove(f.id);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(f.id);
      }
    });
    if (_selected.contains(f.id)) _checkSaved(f);
  }

  Future<void> _removeSelected() async {
    if (_selected.isEmpty) return;
    await ref.read(indexProvider.notifier).removeFromAlbum(widget.albumId, _selected.toList());
    _exitSelection();
  }

  Future<void> _saveSelected(List<FileItem> items) async {
    final chosen = items.where((f) => _selected.contains(f.id)).toList();
    if (chosen.isEmpty) return;
    _exitSelection();
    await ref.read(downloadProvider.notifier).saveManyToDevice(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(indexProvider).index;
    final matches = index.albums.where((a) => a.id == widget.albumId);
    if (matches.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Album not found', style: TextStyle(color: Colors.white54))),
      );
    }
    final album = matches.first;
    final items = index.filesByIds(album.fileIds);

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
                    onPressed: () => _saveSelected(items),
                  ),
                IconButton(
                  icon: const Icon(Icons.playlist_remove),
                  tooltip: 'Remove from album',
                  onPressed: _removeSelected,
                ),
              ],
            )
          : AppBar(title: Text(album.name)),
      body: items.isEmpty
          ? const Center(
              child: Text('This album is empty.\nAdd photos from the Gallery.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 120,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final file = items[i];
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
                          builder: (_) => MediaViewerScreen(items: items, initialIndex: i),
                        ),
                      );
                    }
                  },
                );
              },
            ),
    );
  }
}
