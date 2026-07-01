import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/thumbnail/thumbnail_service.dart';
import '../../../models/file_item.dart';

/// A 44x44 leading thumbnail for a file row. Shows the real image/video
/// preview once fetched; falls back to [fallbackIcon] while loading or when no
/// thumbnail is available.
class FileThumbnail extends StatefulWidget {
  const FileThumbnail({super.key, required this.file, required this.fallbackIcon});

  final FileItem file;
  final IconData fallbackIcon;

  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<FileThumbnail> {
  File? _thumb;
  bool _done = false;

  bool get _previewable =>
      widget.file.mimeType.startsWith('image/') ||
      widget.file.mimeType.startsWith('video/');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FileThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this widget is recycled for a different file (list reorder/filter),
    // its cached thumbnail no longer applies — reload.
    if (oldWidget.file.id != widget.file.id) {
      setState(() { _thumb = null; _done = false; });
      _load();
    }
  }

  void _load() {
    if (_previewable) {
      ThumbnailService.instance.thumbnailFor(widget.file).then((f) {
        if (mounted) setState(() { _thumb = f; _done = true; });
      });
    } else {
      _done = true;
    }
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
                child: const Icon(Icons.play_circle_fill, color: Colors.white70, size: 22),
              ),
          ],
        ),
      );
    }

    // Loading a previewable file: subtle spinner; otherwise the generic icon.
    if (_previewable && !_done) {
      return const SizedBox(
        width: size,
        height: size,
        child: Center(
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    return _fallback(size);
  }

  Widget _fallback(double size) => SizedBox(
        width: size,
        height: size,
        child: Icon(widget.fallbackIcon),
      );
}
