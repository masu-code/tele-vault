import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../gallery/models/gallery_entry.dart';
import '../widgets/media_pages.dart';

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
  late int _current = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final target = (_current + delta).clamp(0, widget.entries.length - 1);
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
            itemCount: widget.entries.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (context, i) {
              final entry = widget.entries[i];
              if (entry.fileItem != null) {
                return entry.isVideo
                    ? CloudVideoPage(key: ValueKey(entry.key), file: entry.fileItem!)
                    : CloudImagePage(key: ValueKey(entry.key), file: entry.fileItem!);
              }
              return entry.isVideo
                  ? LocalVideoPage(key: ValueKey(entry.key), asset: entry.asset!)
                  : LocalImagePage(key: ValueKey(entry.key), asset: entry.asset!);
            },
          ),
        ),
      ),
    );
  }
}
