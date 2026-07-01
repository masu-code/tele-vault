import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../core/download/download_service.dart';
import '../../../models/file_item.dart';
import '../video_controls.dart';

/// Lets a PageView be dragged with a mouse (desktop), not just touch.
class _DragScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

/// Full-screen media viewer with swipe (touch + mouse drag), side arrows, and
/// keyboard ←/→ navigation. Images zoom and pan; videos play with media_kit.
class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({super.key, required this.items, required this.initialIndex});

  final List<FileItem> items;
  final int initialIndex;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  final FocusNode _focus = FocusNode();
  late int _current = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final target = (_current + delta).clamp(0, widget.items.length - 1);
    if (target == _current) return;
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) _go(-1);
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) _go(1);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_current];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${item.name}  (${_current + 1}/${widget.items.length})',
            style: const TextStyle(fontSize: 16)),
      ),
      body: KeyboardListener(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          alignment: Alignment.center,
          children: [
            ScrollConfiguration(
              behavior: _DragScrollBehavior(),
              child: PageView.builder(
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
            ),
            if (_current > 0)
              Positioned(
                left: 8,
                child: _NavArrow(icon: Icons.chevron_left, onTap: () => _go(-1)),
              ),
            if (_current < widget.items.length - 1)
              Positioned(
                right: 8,
                child: _NavArrow(icon: Icons.chevron_right, onTap: () => _go(1)),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavArrow extends StatelessWidget {
  const _NavArrow({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black38,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 32),
        onPressed: onTap,
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
    return Video(controller: _controller, controls: videoControlsWithSafeInsets);
  }
}
