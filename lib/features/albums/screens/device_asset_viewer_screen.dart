import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../preview/widgets/media_pages.dart';
import '../../preview/widgets/photo_zoom_controller.dart';
import '../../preview/widgets/viewer_page_chrome.dart';

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
  final ViewerZoomLock _zoomLock = ViewerZoomLock();
  late int _current = widget.initialIndex;

  /// See MixedMediaViewerScreen._descriptor / _reportDescriptor.
  final ValueNotifier<ViewerChromeDescriptor> _descriptor = ValueNotifier(
    const ViewerChromeDescriptor(),
  );

  @override
  void dispose() {
    _controller.dispose();
    _zoomLock.dispose();
    _descriptor.dispose();
    super.dispose();
  }

  void _reportDescriptor(int pageIndex, ViewerChromeDescriptor descriptor) {
    if (pageIndex != _current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _descriptor.value = descriptor;
    });
  }

  void _go(int delta) {
    final target = (_current + delta).clamp(0, widget.assets.length - 1);
    if (target == _current) return;
    // See MixedMediaViewerScreen._go — updated via setState (so the target
    // page's own build/report runs) the instant the tap is handled, not when
    // the animation settles, so repeated fast taps each advance from the
    // last *requested* page instead of all computing the same target.
    setState(() => _current = target);
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
        // See MixedMediaViewerScreen: a zoomed photo needs horizontal drags
        // for panning, so the PageView stands down while it's zoomed.
        child: ValueListenableBuilder<bool>(
          valueListenable: _zoomLock,
          builder: (context, _, _) => ViewerChromeHost(
            descriptor: _descriptor,
            onPrevious: () => _go(-1),
            onNext: () => _go(1),
            onDismissDragChanged: _zoomLock.reportDragging,
            child: PageView.builder(
              physics: _zoomLock.physics,
              // Builds the adjacent page ahead of the gesture instead of
              // during it. A full-screen photo decode landing mid-swipe is
              // what dropped the frame rate while paging; done a page early
              // it is invisible.
              allowImplicitScrolling: true,
              controller: _controller,
              itemCount: widget.assets.length,
              onPageChanged: (i) => setState(() => _current = i),
              itemBuilder: (context, i) {
                final a = widget.assets[i];
                return a.type == AssetType.video
                    ? LocalVideoPage(
                        key: ValueKey(a.id),
                        asset: a,
                        pageIndex: i,
                        onDescriptor: _reportDescriptor,
                        isCurrent: i == _current,
                      )
                    : LocalImagePage(
                        key: ValueKey(a.id),
                        asset: a,
                        pageIndex: i,
                        onDescriptor: _reportDescriptor,
                        zoomLock: _zoomLock,
                      );
              },
            ),
          ),
        ),
      ),
    );
  }
}
