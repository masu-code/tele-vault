import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../gallery/models/gallery_entry.dart';
import '../widgets/media_pages.dart';
import '../widgets/photo_zoom_controller.dart';
import '../widgets/viewer_page_chrome.dart';

/// Full-screen viewer for the unified Gallery timeline: swipes continuously
/// across a mix of cloud [GalleryEntry.fileItem]s and device-only
/// [GalleryEntry.asset]s with no boundary between the two — each page just
/// reuses whichever of the four existing page widgets fits that entry.
/// When an entry is both on-device and uploaded, the cloud page is used
/// (richer actions: delete-from-Telegram, add-to-album, etc.).
class MixedMediaViewerScreen extends StatefulWidget {
  const MixedMediaViewerScreen({super.key, required this.entries, required this.initialIndex});

  final List<GalleryEntry> entries;
  final int initialIndex;

  @override
  State<MixedMediaViewerScreen> createState() => _MixedMediaViewerScreenState();
}

class _MixedMediaViewerScreenState extends State<MixedMediaViewerScreen> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  final FocusNode _focus = FocusNode();
  final ViewerZoomLock _zoomLock = ViewerZoomLock();
  late int _current = widget.initialIndex;

  /// The currently-showing page's actions/info/zoom — see
  /// [ViewerChromeHost] and [_reportDescriptor].
  final ValueNotifier<ViewerChromeDescriptor> _descriptor = ValueNotifier(
    const ViewerChromeDescriptor(),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheAround(_current));
  }

  // Warms the image cache for the page after [index] — see
  // precacheGalleryEntry. allowImplicitScrolling below gets the *widget*
  // built early; this is what gets the actual decoded pixels ready before
  // the swipe needs them, which is the part that was still landing mid-swipe
  // and dropping frames.
  void _precacheAround(int index) {
    final next = index + 1;
    if (next < widget.entries.length) {
      precacheGalleryEntry(context, widget.entries[next]);
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

  /// Called by whichever page just built itself — see
  /// [CloudImagePage.onDescriptor]. Only the currently-showing page's report
  /// is kept; deferred a frame since this runs mid-build (inside that page's
  /// own build method).
  void _reportDescriptor(int pageIndex, ViewerChromeDescriptor descriptor) {
    if (pageIndex != _current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _descriptor.value = descriptor;
    });
  }

  void _go(int delta) {
    final target = (_current + delta).clamp(0, widget.entries.length - 1);
    if (target == _current) return;
    // Updated (via setState, so the target page's own build/report runs)
    // the instant the tap is handled, not when the animation settles
    // (onPageChanged) — tapping the edge repeatedly, fast, used to compute
    // the *same* target every time (still-mid-animateToPage's _current
    // hadn't caught up yet), so nothing after the first tap looked like it
    // did anything. animateToPage retargeting an animation already in
    // flight is normal, supported behavior — it just smoothly redirects.
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
          // Frozen while a photo is zoomed in (a horizontal drag has to pan
          // it, not flick to the next item) or while ViewerChromeHost is mid
          // swipe-to-dismiss (see _zoomLock.reportDragging) — the PageView
          // must not even try to claim either gesture, not just lose an
          // arena contest for it.
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
                itemCount: widget.entries.length,
                onPageChanged: (i) {
                  setState(() => _current = i);
                  _precacheAround(i);
                },
                itemBuilder: (context, i) {
                  final entry = widget.entries[i];
                  if (entry.fileItem != null) {
                    return entry.isVideo
                        ? CloudVideoPage(
                            key: ValueKey(entry.key),
                            file: entry.fileItem!,
                            pageIndex: i,
                            onDescriptor: _reportDescriptor,
                            isCurrent: i == _current,
                            localAsset: entry.asset,
                          )
                        : CloudImagePage(
                            key: ValueKey(entry.key),
                            file: entry.fileItem!,
                            pageIndex: i,
                            onDescriptor: _reportDescriptor,
                            zoomLock: _zoomLock,
                            localAsset: entry.asset,
                          );
                  }
                  return entry.isVideo
                      ? LocalVideoPage(
                          key: ValueKey(entry.key),
                          asset: entry.asset!,
                          pageIndex: i,
                          onDescriptor: _reportDescriptor,
                          isCurrent: i == _current,
                        )
                      : LocalImagePage(
                          key: ValueKey(entry.key),
                          asset: entry.asset!,
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
