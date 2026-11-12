import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/file_item.dart';
import '../../explorer/providers/index_provider.dart';
import '../../explorer/providers/select_helpers.dart';
import '../../gallery/models/gallery_entry.dart';
import '../../gallery/widgets/gallery_tile.dart';
import '../../gallery/widgets/scroll_idle.dart';
import '../../preview/screens/media_viewer_screen.dart';

/// Archived photos/videos — hidden from Gallery and Albums (see
/// [FileIndex.archivedMediaFiles]) but never deleted. Reached from the
/// account sheet under the profile avatar. Tap opens the normal viewer
/// (Unarchive/Delete are already there via [cloudMediaActions]); long-press
/// selects several at once for the same actions in bulk.
class ArchiveScreen extends ConsumerStatefulWidget {
  const ArchiveScreen({super.key});

  @override
  ConsumerState<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends ConsumerState<ArchiveScreen> {
  final Set<String> _selected = {};
  bool _selecting = false;

  void _exitSelection() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _startSelection(FileItem f) => setState(() {
        _selecting = true;
        _selected.add(f.id);
      });

  void _toggle(FileItem f) => setState(() {
        if (!_selected.remove(f.id)) _selected.add(f.id);
        if (_selected.isEmpty) _selecting = false;
      });

  Future<void> _unarchiveSelected() async {
    final ids = _selected.toList();
    _exitSelection();
    await ref.read(indexProvider.notifier).unarchiveFiles(ids);
  }

  Future<void> _deleteSelected(List<FileItem> items) async {
    final chosen = items.where((f) => _selected.contains(f.id)).toList();
    _exitSelection();
    if (chosen.isNotEmpty) {
      await ref.read(indexProvider.notifier).deleteFiles(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only the archived list, not the whole index.
    final items = ref.watch(
      indexProvider.select((s) => IdentityList(s.index.archivedMediaFiles)),
    ).items;

    ref.listen(indexProvider.select((s) => s.mutationError), (prev, next) {
      if (next != null && next != prev) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: $next')),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(_selecting ? Icons.close : Icons.arrow_back),
          onPressed: _selecting ? _exitSelection : () => Navigator.pop(context),
        ),
        title: Text(_selecting ? '${_selected.length} selected' : 'Archived'),
        actions: _selecting
            ? [
                IconButton(
                  icon: const Icon(Icons.unarchive_outlined),
                  tooltip: 'Unarchive',
                  onPressed: _unarchiveSelected,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete',
                  onPressed: () => _deleteSelected(items),
                ),
              ]
            : null,
      ),
      body: items.isEmpty
          ? const Center(
              child: Text(
                'No archived photos or videos.',
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
