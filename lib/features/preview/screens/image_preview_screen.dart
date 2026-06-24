import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/download/download_service.dart';
import '../../../models/file_item.dart';

/// Full-screen image preview. Downloads the file to the cache (showing
/// progress), then displays it with pinch/scroll zoom and pan.
class ImagePreviewScreen extends StatefulWidget {
  const ImagePreviewScreen({super.key, required this.file});

  final FileItem file;

  @override
  State<ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<ImagePreviewScreen> {
  double _progress = 0;
  File? _local;
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
      if (mounted) setState(() => _local = file);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
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
            const Icon(Icons.broken_image_outlined, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
          ],
        ),
      );
    }
    if (_local == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(value: _progress == 0 ? null : _progress),
          const SizedBox(height: 16),
          Text('${(_progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white70)),
        ],
      );
    }
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 5,
      child: Image.file(
        _local!,
        errorBuilder: (_, _, _) => const Text(
          'Could not display this image.',
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}
