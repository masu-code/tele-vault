import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../models/gallery_entry.dart';

/// A square gallery cell. Its thumbnail is requested in [initState] and
/// cancelled in [dispose] — the surrounding `SliverGrid` already builds and
/// destroys tiles lazily based on the viewport (plus `cacheExtent`), so that
/// lifecycle alone is enough to load only what's near-screen; no separate
/// visibility-polling package is needed on top of it. Supports a selected
/// state for multi-select.
///
/// Renders either a cloud [GalleryEntry.fileItem] (preferred when both are
/// present — cache/pool-managed by [ThumbnailService], independent of whether
/// the device copy still exists) or a device-only [GalleryEntry.asset]
/// (also cache/pool-managed by [ThumbnailService], via `localThumbnailFor`).
class GalleryTile extends StatefulWidget {
  const GalleryTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
  });

  final GalleryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selected;

  @override
  State<GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<GalleryTile> {
  File? _cloudThumb;
  Uint8List? _localThumb;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(GalleryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this cell is recycled for a different entry, reload its thumbnail.
    if (oldWidget.entry.key != widget.entry.key) {
      _cancel(oldWidget.entry);
      setState(() {
        _cloudThumb = null;
        _localThumb = null;
        _done = false;
      });
      _request();
    }
  }

  @override
  void dispose() {
    _cancel(widget.entry);
    super.dispose();
  }

  void _cancel(GalleryEntry entry) {
    // Cancellation only applies to the cloud path — ThumbnailService's
    // pool/cancel machinery exists for Telegram network fetches. Local
    // thumbnails are cheap/cached, so an in-flight one is left to finish and
    // populate the cache for next time rather than aborted.
    if (!_done && entry.fileItem != null) {
      ThumbnailService.instance.cancel(entry.fileItem!.id);
    }
  }

  void _request() {
    final fileItem = widget.entry.fileItem;
    if (fileItem != null) {
      ThumbnailService.instance.thumbnailFor(fileItem).then((f) {
        if (mounted) setState(() { _cloudThumb = f; _done = true; });
      });
    } else {
      ThumbnailService.instance.localThumbnailFor(widget.entry.asset!).then((data) {
        if (mounted) setState(() { _localThumb = data; _done = true; });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onLongPress, // right-click on desktop
        child: Container(
          color: const Color(0xFF1C1C1E),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_cloudThumb != null)
                Image.file(
                  _cloudThumb!,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  errorBuilder: (_, _, _) => _placeholder(entry.isVideo),
                )
              else if (_localThumb != null)
                Image.memory(
                  _localThumb!,
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  errorBuilder: (_, _, _) => _placeholder(entry.isVideo),
                )
              else if (!_done)
                const Center(
                  child: SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                _placeholder(entry.isVideo),
              if (entry.isVideo && !widget.selected)
                const Align(
                  child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 32),
                ),
              // Subtle cloud badge — the only status shown on the tile itself
              // (no separate "on device" icon here, unlike the single-item
              // viewer's two independent indicators).
              if (entry.isUploaded && !widget.selected)
                const Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    Icons.cloud_done_outlined,
                    size: 14,
                    color: Colors.white70,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 3)],
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
