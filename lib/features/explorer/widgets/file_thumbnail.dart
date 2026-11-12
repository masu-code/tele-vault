import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../../../models/file_item.dart';
import '../../gallery/widgets/scroll_idle.dart';

/// A 44x44 leading thumbnail for a file row. Shows the real image/video
/// preview once fetched; falls back to [fallbackIcon] while loading or when no
/// thumbnail is available.
class FileThumbnail extends StatefulWidget {
  const FileThumbnail({
    super.key,
    required this.file,
    required this.fallbackIcon,
  });

  final FileItem file;
  final IconData fallbackIcon;

  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<FileThumbnail> {
  File? _thumb;
  bool _done = false;
  Timer? _startTimer;
  ValueListenable<bool>? _scrollIdle;

  // Same 120ms debounce as GalleryTile, for the same reason: a small buffer
  // against firing a request for a row that's about to scroll straight back
  // out of view.
  static const _requestDelay = Duration(milliseconds: 120);

  bool get _previewable =>
      widget.file.mimeType.startsWith('image/') ||
      widget.file.mimeType.startsWith('video/');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // See GalleryTile's didChangeDependencies for why this lookup happens
    // here rather than in initState.
    final idle = ScrollIdle.maybeOf(context);
    if (idle != _scrollIdle) {
      _scrollIdle?.removeListener(_onScrollIdleChanged);
      _scrollIdle = idle;
      _scrollIdle?.addListener(_onScrollIdleChanged);
      _maybeRequest();
    }
  }

  @override
  void didUpdateWidget(FileThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this widget is recycled for a different file (list reorder/filter),
    // its cached thumbnail no longer applies — reload.
    if (oldWidget.file.id != widget.file.id) {
      _startTimer?.cancel();
      _startTimer = null;
      setState(() {
        _thumb = null;
        _done = false;
      });
      _maybeRequest();
    }
  }

  @override
  void dispose() {
    _scrollIdle?.removeListener(_onScrollIdleChanged);
    _startTimer?.cancel();
    super.dispose();
  }

  void _onScrollIdleChanged() => _maybeRequest();

  /// Skips starting the request entirely while the list is actively
  /// scrolling — not just delaying it — so opening a folder full of files
  /// and immediately flinging through it doesn't queue a decode for every
  /// row that happened to be on screen for a moment. [_onScrollIdleChanged]
  /// picks it back up once the list settles.
  void _maybeRequest() {
    if (!_previewable) {
      _done = true;
      return;
    }
    if (_done || _startTimer != null) return;
    if (_scrollIdle?.value == false) return;
    _startTimer = Timer(_requestDelay, () {
      if (!mounted) return;
      ThumbnailService.instance.thumbnailFor(widget.file).then((f) {
        if (mounted)
          setState(() {
            _thumb = f;
            _done = true;
          });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    final isVideo = widget.file.mimeType.startsWith('video/');

    if (_thumb != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.file(
              _thumb!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: 128,
              errorBuilder: (_, _, _) => _fallback(size),
            ),
            if (isVideo)
              Container(
                width: size,
                height: size,
                color: Colors.black26,
                child: const Icon(
                  Icons.play_circle_fill,
                  color: Colors.white70,
                  size: 22,
                ),
              ),
          ],
        ),
      );
    }

    // Deliberately a flat box while loading, not a spinner — see
    // GalleryTile for why: a folder full of these animating at once
    // competes for the same frame budget opening the folder needs.
    if (_previewable && !_done) {
      return const SizedBox(width: size, height: size);
    }
    return _fallback(size);
  }

  Widget _fallback(double size) =>
      SizedBox(width: size, height: size, child: Icon(widget.fallbackIcon));
}
