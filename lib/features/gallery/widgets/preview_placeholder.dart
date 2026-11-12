import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:tv_core/codecs.dart';

/// Process-wide LRU of decoded ThumbHash images (at most 32 px each), keyed by
/// thumbnail key.
///
/// The cache owns the "master" [ui.Image]. Widgets never hold it: they take a
/// [ui.Image.clone] and dispose that, so evicting (and disposing) a master
/// while a tile still paints it is safe.
class PreviewImageCache {
  PreviewImageCache({this.capacity = 500});

  static final PreviewImageCache instance = PreviewImageCache();

  final int capacity;

  // Insertion order = recency (a hit re-inserts at the end).
  final LinkedHashMap<String, ui.Image> _images = LinkedHashMap();
  final Map<String, Future<ui.Image?>> _pending = {};

  int get length => _images.length;

  /// A clone of the cached image for [key], or null. The caller disposes it.
  ui.Image? cloneIfCached(String key) {
    final image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image;
    return image.clone();
  }

  /// Decodes [hash] (at most once per key at a time) and caches the result.
  /// Completes with a clone the caller disposes, or null when the hash is
  /// invalid or the engine cannot decode it. Never throws.
  Future<ui.Image?> load(String key, Uint8List hash) async {
    final hit = cloneIfCached(key);
    if (hit != null) return hit;
    final master = await (_pending[key] ??= _decode(key, hash));
    return master?.clone();
  }

  Future<ui.Image?> _decode(String key, Uint8List hash) async {
    try {
      final px = thumbHashToRGBA(hash);
      if (px == null) return null;
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        px.rgba,
        px.width,
        px.height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future;
      _images.remove(key)?.dispose();
      _images[key] = image;
      while (_images.length > capacity) {
        _images.remove(_images.keys.first)?.dispose();
      }
      return image;
    } catch (_) {
      return null;
    } finally {
      _pending.remove(key);
    }
  }

  /// Disposes every cached image (tests).
  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }
}

/// A ThumbHash preview, stretched to cover its box. Painted from the shared
/// [PreviewImageCache]; the first build is synchronous when the image is
/// already cached, otherwise it decodes once and fades in nothing (the base
/// colour stays under it, so there is never a hole).
class PreviewImage extends StatefulWidget {
  const PreviewImage({super.key, required this.cacheKey, required this.hash});

  final String cacheKey;
  final Uint8List hash;

  @override
  State<PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends State<PreviewImage> {
  ui.Image? _image;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(PreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _set(null);
      _resolve();
    }
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  void _set(ui.Image? image) {
    _image?.dispose();
    _image = image;
  }

  void _resolve() {
    final cache = PreviewImageCache.instance;
    final hit = cache.cloneIfCached(widget.cacheKey);
    if (hit != null) {
      _set(hit);
      return;
    }
    final generation = ++_generation;
    cache.load(widget.cacheKey, widget.hash).then((image) {
      if (image == null) return;
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      setState(() => _set(image));
    });
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return const SizedBox.expand();
    return RawImage(
      image: image,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
    );
  }
}
