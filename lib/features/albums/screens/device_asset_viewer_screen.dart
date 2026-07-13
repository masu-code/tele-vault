import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../preview/widgets/media_pages.dart';

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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ScrollConfiguration(
        behavior: DragScrollBehavior(),
        child: PageView.builder(
          controller: _controller,
          itemCount: widget.assets.length,
          itemBuilder: (context, i) {
            final a = widget.assets[i];
            return a.type == AssetType.video
                ? LocalVideoPage(key: ValueKey(a.id), asset: a)
                : LocalImagePage(key: ValueKey(a.id), asset: a);
          },
        ),
      ),
    );
  }
}
