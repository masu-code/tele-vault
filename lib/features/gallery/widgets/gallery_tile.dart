import 'dart:io';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../../../models/file_item.dart';

/// A square gallery cell. Its thumbnail is requested only once the cell scrolls
/// into view, and cancelled when it scrolls fully out — so a large gallery
/// loads just what's on screen. Videos get a play overlay.
class GalleryTile extends StatefulWidget {
  const GalleryTile({super.key, required this.file, required this.onTap});

  final FileItem file;
  final VoidCallback onTap;

  @override
  State<GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<GalleryTile> {
  File? _thumb;
  bool _requested = false;
  bool _done = false;

  void _request() {
    _requested = true;
    ThumbnailService.instance.thumbnailFor(widget.file).then((f) {
      if (mounted) setState(() { _thumb = f; _done = true; });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.file.mimeType.startsWith('video/');
    return VisibilityDetector(
      key: Key('gtile_${widget.file.id}'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        if (info.visibleFraction == 0) {
          if (!_done) ThumbnailService.instance.cancel(widget.file.id);
        } else if (!_requested) {
          _request();
        }
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: const Color(0xFF1C1C1E),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_thumb != null)
                Image.file(
                  _thumb!,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  errorBuilder: (_, _, _) => _placeholder(isVideo),
                )
              else if (_requested && !_done)
                const Center(
                  child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                _placeholder(isVideo),
              if (isVideo)
                const Align(
                  child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 32),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(bool isVideo) => Center(
        child: Icon(
          isVideo ? Icons.movie_outlined : Icons.image_outlined,
          color: Colors.white30,
        ),
      );
}
