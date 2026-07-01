import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../preview/video_controls.dart';

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

/// Full-screen viewer for photos/videos that live only on the device (not yet
/// uploaded). Reads straight from the local file, so it opens instantly —
/// no Telegram download involved.
class DeviceAssetViewerScreen extends StatefulWidget {
  const DeviceAssetViewerScreen({
    super.key,
    required this.assets,
    required this.initialIndex,
  });

  final List<AssetEntity> assets;
  final int initialIndex;

  @override
  State<DeviceAssetViewerScreen> createState() => _DeviceAssetViewerScreenState();
}

class _DeviceAssetViewerScreenState extends State<DeviceAssetViewerScreen> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _current = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${_current + 1}/${widget.assets.length}',
            style: const TextStyle(fontSize: 16)),
      ),
      body: ScrollConfiguration(
        behavior: _DragScrollBehavior(),
        child: PageView.builder(
          controller: _controller,
          itemCount: widget.assets.length,
          onPageChanged: (i) => setState(() => _current = i),
          itemBuilder: (context, i) {
            final a = widget.assets[i];
            return a.type == AssetType.video
                ? _LocalVideoPage(key: ValueKey(a.id), asset: a)
                : _LocalImagePage(key: ValueKey(a.id), asset: a);
          },
        ),
      ),
    );
  }
}

class _LocalImagePage extends StatefulWidget {
  const _LocalImagePage({super.key, required this.asset});
  final AssetEntity asset;

  @override
  State<_LocalImagePage> createState() => _LocalImagePageState();
}

class _LocalImagePageState extends State<_LocalImagePage> {
  File? _local;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.asset.file.then((f) {
      if (!mounted) return;
      if (f == null) {
        setState(() => _error = 'Could not read this photo from the device.');
      } else {
        setState(() => _local = f);
      }
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
      return const Center(child: CircularProgressIndicator());
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

class _LocalVideoPage extends StatefulWidget {
  const _LocalVideoPage({super.key, required this.asset});
  final AssetEntity asset;

  @override
  State<_LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<_LocalVideoPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await widget.asset.file;
      if (file == null) throw Exception('Could not read this video from the device.');
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
      return const Center(child: CircularProgressIndicator());
    }
    return Video(controller: _controller, controls: videoControlsWithSafeInsets);
  }
}
