import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/diag/tv_stats.dart';
import '../../../core/thumbnail/preview_table.dart';
import '../../../core/thumbnail/thumb_prefetcher.dart';
import '../../../core/thumbnail/thumb_store.dart';
import '../models/gallery_entry.dart';
import 'preview_placeholder.dart';

/// Colour painted under a tile that has neither a preview nor a thumbnail yet.
const int kTileFallbackColor = 0xFF2A2A2E;

/// A square gallery cell, device or cloud, keyed by [GalleryEntry.thumbKey].
///
/// Paint order, cheapest first, every layer synchronous or local:
///  1. a flat box of the preview's average colour ([PreviewTable]);
///  2. the decoded ThumbHash preview ([PreviewImage]);
///  3. the stored JPEG ([ThumbStore]), shown once its first frame is ready.
///
/// The tile itself never touches the network or a platform channel. It only
/// tells the [ThumbPrefetcher] which key is on (or near) screen
/// ([ThumbPrefetcher.prioritize] in `initState`/`didUpdateWidget`,
/// [ThumbPrefetcher.deprioritize] in `dispose`) and repaints when the
/// [ThumbStore] reports a new file. There are no timers and no dependency on
/// scrolling state: Flutter's own scroll-aware image deferral covers flings.
class GalleryTile extends StatefulWidget {
  const GalleryTile({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
  });

  final GalleryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selected;

  @override
  State<GalleryTile> createState() => _GalleryTileState();
}

class _GalleryTileState extends State<GalleryTile> {
  bool _listening = false;
  bool _hadPreview = false;

  ThumbStore get _store => ThumbStore.instance;

  @override
  void initState() {
    super.initState();
    TvStats.tileInit();
    _track(widget.entry);
  }

  @override
  void didUpdateWidget(GalleryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.thumbKey != widget.entry.thumbKey ||
        oldWidget.entry.key != widget.entry.key) {
      ThumbPrefetcher.instance.deprioritize(oldWidget.entry.thumbKey);
      _track(widget.entry);
    }
  }

  @override
  void dispose() {
    _stopListening();
    ThumbPrefetcher.instance.deprioritize(widget.entry.thumbKey);
    super.dispose();
  }

  /// Registers [entry] with the prefetcher and decides whether this tile has
  /// to wait for the store.
  void _track(GalleryEntry entry) {
    _hadPreview = PreviewTable.instance.hash(entry.thumbKey) != null;
    if (_store.has(entry.thumbKey)) {
      _stopListening();
      return;
    }
    ThumbPrefetcher.instance.prioritize(
      ThumbRequest(
        key: entry.thumbKey,
        file: entry.fileItem,
        assetId: entry.asset?.id,
        asset: entry.asset,
      ),
    );
    if (!_listening) {
      _store.revision.addListener(_onRevision);
      PreviewTable.instance.revision.addListener(_onRevision);
      _listening = true;
    }
  }

  void _stopListening() {
    if (!_listening) return;
    _store.revision.removeListener(_onRevision);
    PreviewTable.instance.revision.removeListener(_onRevision);
    _listening = false;
  }

  // Only while the file is missing. Rebuild when it showed up, or when the
  // preview did (a pack installs previews together with its files; an upload,
  // an index import or the backfill can add one on its own).
  void _onRevision() {
    if (!mounted) return;
    final key = widget.entry.thumbKey;
    final hasFile = _store.has(key);
    final hasPreview = PreviewTable.instance.hash(key) != null;
    if (hasFile) _stopListening();
    if (hasFile || (hasPreview && !_hadPreview)) {
      setState(() => _hadPreview = hasPreview);
    }
  }

  @override
  Widget build(BuildContext context) {
    TvStats.tileBuild();
    final entry = widget.entry;
    final key = entry.thumbKey;
    final table = PreviewTable.instance;
    final average = table.averageArgb(key);
    final hash = table.hash(key);
    final file = _store.fileIfPresent(key);
    if (average == null && hash == null && file == null) TvStats.tileBlank();
    final showPlay = entry.isVideo && !widget.selected;

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onLongPress, // right-click on desktop
      child: ColoredBox(
        color: Color(
          average == null ? kTileFallbackColor : average | 0xFF000000,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hash != null) PreviewImage(cacheKey: key, hash: hash),
            if (file != null) _storedThumb(file, key),
            if (showPlay)
              const Align(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white70,
                  size: 32,
                ),
              ),
            // The only status shown on the tile: uploaded (no separate "on
            // device" icon here, unlike the single-item viewer's two).
            if (entry.isUploaded && !widget.selected)
              const Positioned(top: 4, right: 4, child: _CloudBadge()),
            if (widget.selected) ...[
              const ColoredBox(color: Color(0x662AABEE)),
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.check_circle,
                    color: Color(0xFF2AABEE),
                    size: 22,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _storedThumb(File file, String key) {
    return Image.file(
      file,
      key: ValueKey(key),
      fit: BoxFit.cover,
      cacheWidth: 300,
      gaplessPlayback: true,
      // Nothing is painted until the first frame, so the preview underneath
      // is never replaced by a blank while the JPEG decodes.
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
          (wasSynchronouslyLoaded || frame != null)
          ? child
          : const SizedBox.shrink(),
      errorBuilder: (context, error, stack) {
        // A damaged file: drop it so the prefetcher fetches it again.
        _store.reportCorrupt(key).then((_) {
          // The key is no longer in the store: ask for it again.
          if (mounted && widget.entry.thumbKey == key) {
            setState(() => _track(widget.entry));
          }
        });
        return const SizedBox.shrink();
      },
    );
  }
}

class _CloudBadge extends StatelessWidget {
  const _CloudBadge();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        color: Color(0x66000000),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: EdgeInsets.all(2),
        child: Icon(Icons.cloud_done_outlined, size: 12, color: Colors.white70),
      ),
    );
  }
}

/// A [GalleryTile] whose `selected` flag follows one key in [selection].
///
/// Only the tile whose membership changed rebuilds: every wrapper listens, but
/// each one calls `setState` only when its own answer flipped, so toggling one
/// item neither rebuilds the screen nor the other tiles.
class SelectionScopedTile extends StatefulWidget {
  const SelectionScopedTile({
    super.key,
    required this.entry,
    required this.selection,
    required this.onTap,
    required this.onLongPress,
  });

  final GalleryEntry entry;
  final ValueListenable<Set<String>> selection;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<SelectionScopedTile> createState() => _SelectionScopedTileState();
}

class _SelectionScopedTileState extends State<SelectionScopedTile> {
  late bool _selected = widget.selection.value.contains(widget.entry.key);

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_onSelection);
  }

  @override
  void didUpdateWidget(SelectionScopedTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection.removeListener(_onSelection);
      widget.selection.addListener(_onSelection);
    }
    _selected = widget.selection.value.contains(widget.entry.key);
  }

  @override
  void dispose() {
    widget.selection.removeListener(_onSelection);
    super.dispose();
  }

  void _onSelection() {
    final now = widget.selection.value.contains(widget.entry.key);
    if (now != _selected) setState(() => _selected = now);
  }

  @override
  Widget build(BuildContext context) {
    return GalleryTile(
      entry: widget.entry,
      selected: _selected,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
    );
  }
}
