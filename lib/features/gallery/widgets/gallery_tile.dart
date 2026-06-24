import 'dart:io';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../../../models/file_item.dart';

/// A square gallery cell. Its thumbnail is requested only once the cell scrolls
/// into view and cancelled when it scrolls out, so a large gallery loads just
/// what's on screen. Supports a selected state for multi-select.
class GalleryTile extends StatefulWidget {
  const GalleryTile({
    super.key,
    required this.file,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
  });

  final FileItem file;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selected;

  @override
  State<GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<GalleryTile> {
  File? _thumb;
  bool _requested = false;
  bool _done = false;

  @override
  void didUpdateWidget(GalleryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this cell is recycled for a different file, reload its thumbnail.
    if (oldWidget.file.id != widget.file.id) {
      setState(() {
        _thumb = null;
        _requested = false;
        _done = false;
      });
      _request();
    }
  }

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
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onLongPress, // right-click on desktop
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
              if (isVideo && !widget.selected)
                const Align(
                  child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 32),
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
