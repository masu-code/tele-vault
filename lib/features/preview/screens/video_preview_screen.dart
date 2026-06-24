import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../../core/download/download_service.dart';
import '../../../models/file_item.dart';

/// In-app video player. Downloads the file to cache (showing progress), then
/// plays it with media_kit (works on Windows and Android). Multi-part files
/// are reassembled into one local file by the download layer first.
class VideoPreviewScreen extends StatefulWidget {
  const VideoPreviewScreen({super.key, required this.file});

  final FileItem file;

  @override
  State<VideoPreviewScreen> createState() => _VideoPreviewScreenState();
}

class _VideoPreviewScreenState extends State<VideoPreviewScreen> {
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.file.name, style: const TextStyle(fontSize: 16)),
      ),
      body: Center(child: _buildContent()),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
          ],
        ),
      );
    }
    if (!_ready) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(value: _progress == 0 ? null : _progress),
          const SizedBox(height: 16),
          Text('Downloading ${(_progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white70)),
        ],
      );
    }
    return Video(controller: _controller);
  }
}
