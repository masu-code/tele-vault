import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../models/file_item.dart';
import '../widgets/media_pages.dart';
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: ScrollConfiguration(
          behavior: DragScrollBehavior(),
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (context, i) {
              final media = widget.items[i];
              void previous() => _go(-1);
              void next() => _go(1);
              return media.mimeType.startsWith('video/')
                  ? CloudVideoPage(
                      key: ValueKey(media.id),
                      file: media,
                      onPrevious: previous,
                      onNext: next,
                    )
                  : CloudImagePage(
                      key: ValueKey(media.id),
                      file: media,
                      onPrevious: previous,
                      onNext: next,
                    );
            },
          ),
        ),
      ),
    );
  }
}
