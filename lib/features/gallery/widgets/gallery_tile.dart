import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../models/gallery_entry.dart';

/// A square gallery cell. Its thumbnail is requested shortly after the tile
/// is built and cancelled in [dispose] — the surrounding `SliverGrid` already
/// builds and destroys tiles lazily based on the viewport (plus
/// `scrollCacheExtent`), so that lifecycle alone decides what loads.
/// Supports a selected state for multi-select.
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
  Timer? _startTimer;

  /// How long a tile has to survive before its thumbnail is actually
  /// requested. A fast fling builds and destroys rows faster than this, so
  /// those tiles come and go without ever enqueueing work — only whatever is
  /// still alive once the scroll settles asks for anything. This is what
  /// keeps a flick from burying the queue under requests for rows that are
  /// already gone. Anything already in memory skips the wait entirely (see
  /// [_request]), so scrolling back over loaded content stays instant.
  static const _requestDelay = Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(GalleryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this cell is recycled for a different entry, reload its thumbnail.
    // No setState needed — a rebuild always follows didUpdateWidget.
    if (oldWidget.entry.key != widget.entry.key) {
      _cancel(oldWidget.entry);
      _cloudThumb = null;
      _localThumb = null;
      _done = false;
      _request();
    }
  }

  @override
  void dispose() {
    _cancel(widget.entry);
    super.dispose();
  }

  /// The id [_request] would fetch this entry under — cloud when available,
  /// device asset otherwise. [cancel] has to use the identical key.
  String _requestId(GalleryEntry entry) =>
      entry.fileItem?.id ?? entry.asset!.id;

  void _cancel(GalleryEntry entry) {
    _startTimer?.cancel();
    if (_done) return;
    ThumbnailService.instance.cancel(_requestId(entry));
  }

  void _request() {
    final service = ThumbnailService.instance;
    final entry = widget.entry;
    final fileItem = entry.fileItem;

    // Already decoded and in memory — paint it now rather than paying the
    // debounce (and a pool round-trip) for something we already have.
    if (fileItem != null) {
      final hit = service.cachedCloud(fileItem.id);
      if (hit != null) {
        _cloudThumb = hit;
        _done = true;
        return;
      }
    } else {
      final hit = service.cachedLocal(entry.asset!.id);
      if (hit != null) {
        _localThumb = hit;
        _done = true;
        return;
      }
    }

    _startTimer = Timer(_requestDelay, () {
      if (!mounted) return;
      if (fileItem != null) {
        service.thumbnailFor(fileItem).then((f) {
          if (mounted) setState(() { _cloudThumb = f; _done = true; });
        });
      } else {
        service.localThumbnailFor(entry.asset!).then((data) {
          if (mounted) setState(() { _localThumb = data; _done = true; });
        });
      }
    });
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
              else
                // Deliberately a flat box while loading, not a spinner: a
                // screenful of CircularProgressIndicators animates every
                // frame, so the placeholder itself was competing for the
                // frame budget during exactly the scroll it was meant to
                // cover. Matches how Telegram/Google Photos show an empty
                // cell until the image is ready.
                const SizedBox.shrink(),
              if (entry.isVideo && (_cloudThumb != null || _localThumb != null) && !widget.selected)
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
