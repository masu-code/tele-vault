import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../explorer/providers/index_provider.dart';
import '../../preview/screens/media_viewer_screen.dart';
import '../widgets/gallery_tile.dart';

/// Google Photos-style grid of every image and video in the vault, newest
/// first. Tap a cell to open the full-screen swipeable viewer.
class GalleryScreen extends ConsumerWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(indexProvider);
    final media = state.index.mediaFiles;

    return Scaffold(
      appBar: AppBar(title: const Text('Gallery')),
      body: _body(context, state, media),
    );
  }

  Widget _body(BuildContext context, IndexState state, List media) {
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
      itemBuilder: (context, i) => GalleryTile(
        file: media[i],
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              items: media.cast(),
              initialIndex: i,
            ),
          ),
        ),
      ),
    );
  }
}
