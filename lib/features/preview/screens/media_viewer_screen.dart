import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/file_item.dart';
import '../../gallery/models/gallery_entry.dart';
import '../widgets/media_pages.dart';
import '../widgets/photo_zoom_controller.dart';
import '../widgets/viewer_page_chrome.dart';
// Re-exported so existing callers (Explorer, vault Albums, Gallery) that
// import this file for shareCloudFiles/cloudMediaActions/etc. keep working
// unchanged after those helpers moved into media_pages.dart.
export '../widgets/media_pages.dart';

/// Full-screen media viewer with swipe (touch + mouse drag) and keyboard ←/→
/// navigation. Tap toggles floating actions; swipe up reveals info. Images
/// zoom and pan; videos play with media_kit.
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
  final ViewerZoomLock _zoomLock = ViewerZoomLock();
  late int _current = widget.initialIndex;

  /// See MixedMediaViewerScreen._descriptor / _reportDescriptor.
  final ValueNotifier<ViewerChromeDescriptor> _descriptor = ValueNotifier(
    const ViewerChromeDescriptor(),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAround(_current));
  }

  // See MixedMediaViewerScreen._precacheAround — same fix, same reason (forward neighbour only).
  void _precacheAround(int index) {
    final next = index + 1;
    if (next < widget.items.length) {
      precacheGalleryEntry(context, GalleryEntry(fileItem: widget.items[next]));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
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
    final target = (_current + delta).clamp(0, widget.items.length - 1);
    if (target == _current) return;
    // See MixedMediaViewerScreen._go — updated via setState (so the target
    // page's own build/report runs) the instant the tap is handled, not when
    // the animation settles, so repeated fast taps each advance from the
    // last *requested* page instead of all computing the same target.
    setState(() => _current = target);
    _precacheAround(target);
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: ScrollConfiguration(
          behavior: DragScrollBehavior(),
          // See MixedMediaViewerScreen: a zoomed photo needs horizontal
          // drags for panning, so the PageView stands down while it's zoomed.
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
                // what dropped the frame rate while paging; done a page
                // early it is invisible.
                allowImplicitScrolling: true,
                controller: _controller,
                itemCount: widget.items.length,
                onPageChanged: (i) {
                  setState(() => _current = i);
                  _precacheAround(i);
                },
                itemBuilder: (context, i) {
                  final media = widget.items[i];
                  return media.mimeType.startsWith('video/')
                      ? CloudVideoPage(
                          key: ValueKey(media.id),
                          file: media,
                          pageIndex: i,
                          onDescriptor: _reportDescriptor,
                          isCurrent: i == _current,
                        )
                      : CloudImagePage(
                          key: ValueKey(media.id),
                          file: media,
                          pageIndex: i,
                          onDescriptor: _reportDescriptor,
                          zoomLock: _zoomLock,
                        );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
