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

  void _go(int delta) {
    final page = _controller.page?.round() ?? widget.initialIndex;
    final target = (page + delta).clamp(0, widget.assets.length - 1);
    if (target == page) return;
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
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
            void previous() => _go(-1);
            void next() => _go(1);
            return a.type == AssetType.video
                ? LocalVideoPage(
                    key: ValueKey(a.id),
                    asset: a,
                    onPrevious: previous,
                    onNext: next,
                  )
                : LocalImagePage(
                    key: ValueKey(a.id),
                    asset: a,
                    onPrevious: previous,
                    onNext: next,
                  );
          },
        ),
      ),
    );
  }
}
