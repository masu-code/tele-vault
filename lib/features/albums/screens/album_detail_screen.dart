import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/local_storage/local_file_service.dart';
import '../../download/providers/download_provider.dart';
import '../../explorer/providers/index_provider.dart';
import '../../explorer/providers/select_helpers.dart';
import '../../explorer/widgets/save_to_device_button.dart';
import '../../gallery/models/gallery_entry.dart';
import '../../gallery/widgets/gallery_tile.dart';
import '../../gallery/widgets/scroll_idle.dart';
import '../../preview/screens/media_viewer_screen.dart';
import '../../../models/album.dart';
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
    await ref
        .read(indexProvider.notifier)
        .removeFromAlbum(widget.albumId, _selected.toList());
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
    // Watch only this album and its visible members, not the whole index:
    // an unrelated upload or rename must not rebuild the grid.
    final view = ref.watch(
      indexProvider.select((s) {
        final index = s.index;
        Album? album;
        for (final a in index.albums) {
          if (a.id == widget.albumId) {
            album = a;
            break;
          }
        }
        if (album == null) return const _AlbumView(null, IdentityList(<FileItem>[]));
        // Archived files stay members of the album (so unarchiving brings
        // them right back) but don't show while archived, same as Gallery.
        return _AlbumView(
          album,
          IdentityList(
            index.filesByIds(album.fileIds).where((f) => !f.archived).toList(),
          ),
        );
      }),
    );
    final album = view.album;
    if (album == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text(
            'Album not found',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    final items = view.items.items;

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
    ref.listen(indexProvider.select((s) => s.mutationError), (prev, next) {
      if (next != null && next != prev) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: $next')),
        );
      }
    });

    final allSaved =
        _selected.isNotEmpty && _selected.every((id) => _savedIds.contains(id));

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              ),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.share_outlined),
                  tooltip: 'Share',
                  onPressed: () => shareCloudFiles(
                    context,
                    items.where((f) => _selected.contains(f.id)).toList(),
                  ),
                ),
                // Cloud-backup status: always uploaded here — informational.
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Icon(
                      Icons.cloud_done_outlined,
                      color: Color(0xFF2AABEE),
                    ),
                  ),
                ),
                // Device-presence status: Download (pending) or On device (done).
                if (allSaved)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: Icon(
                        onDeviceIcon(),
                        color: const Color(0xFF2AABEE),
                      ),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.download_outlined),
                    tooltip: 'Download',
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
              child: Text(
                'This album is empty.\nAdd photos from the Gallery.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ScrollIdleTracker(
              child: GridView.builder(
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
                    entry: GalleryEntry(fileItem: file),
                    selected: _selected.contains(file.id),
                    onLongPress: () =>
                        _selecting ? _toggle(file) : _startSelection(file),
                    onTap: () {
                      if (_selecting) {
                        _toggle(file);
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MediaViewerScreen(
                              items: items,
                              initialIndex: i,
                            ),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
            ),
    );
  }
}

/// What the album screen renders: the album record and its visible files.
class _AlbumView {
  const _AlbumView(this.album, this.items);

  final Album? album;
  final IdentityList<FileItem> items;

  @override
  bool operator ==(Object other) =>
      other is _AlbumView &&
      identical(other.album, album) &&
      other.items == items;

  @override
  int get hashCode => Object.hash(album, items);
}
