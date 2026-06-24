import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../core/download/download_service.dart';
import '../../../models/file_item.dart';

/// Full-screen media viewer with horizontal swipe between items. Images zoom
/// and pan; videos play with media_kit. Used by the gallery and albums.
class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({super.key, required this.items, required this.initialIndex});

  final List<FileItem> items;
  final int initialIndex;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _current = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_current];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(item.name, style: const TextStyle(fontSize: 16)),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.items.length,
        onPageChanged: (i) => setState(() => _current = i),
        itemBuilder: (context, i) {
          final media = widget.items[i];
          return media.mimeType.startsWith('video/')
              ? _VideoPage(key: ValueKey(media.id), file: media)
              : _ImagePage(key: ValueKey(media.id), file: media);
        },
      ),
    );
  }
}

class _ImagePage extends StatefulWidget {
  const _ImagePage({super.key, required this.file});
  final FileItem file;

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage> {
  double _progress = 0;
  File? _local;
  String? _error;

  @override
  void initState() {
    super.initState();
    DownloadService.instance.downloadToCache(
      widget.file,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    ).then((f) {
      if (mounted) setState(() => _local = f);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    if (_local == null) {
      return Center(
        child: CircularProgressIndicator(value: _progress == 0 ? null : _progress),
      );
    }
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 5,
      child: Center(
        child: Image.file(
          _local!,
          errorBuilder: (_, _, _) =>
              const Text('Could not display image.', style: TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({super.key, required this.file});
  final FileItem file;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  double _progress = 0;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await DownloadService.instance.downloadToCache(
        widget.file,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      await _player.open(Media(file.path));
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)));
    }
    if (!_ready) {
      return Center(
        child: CircularProgressIndicator(value: _progress == 0 ? null : _progress),
      );
    }
    return Video(controller: _controller);
  }
}
