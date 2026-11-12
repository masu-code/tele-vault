import 'package:flutter/material.dart';

/// Owns a photo page's pan/zoom transform: the [InteractiveViewer]'s
/// controller, the "is zoomed in" flag the surrounding gestures key off, and
/// the animated double-tap zoom.
///
/// The flag matters more than it looks: a zoomed photo has to keep one-finger
/// drags for panning, so BOTH [ViewerChromeHost]'s swipe gestures and the
/// enclosing PageView's horizontal scroll have to stand down while it's true.
/// Without the PageView half of that, dragging to look around a zoomed photo
/// just flicked to the next one instead.
class PhotoZoomController {
  PhotoZoomController(TickerProvider vsync)
    : _animation = AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 200),
      ) {
    transform.addListener(_syncZoomed);
    _animation.addListener(() {
      final matrix = _tween?.value;
      if (matrix != null) transform.value = matrix;
    });
  }

  /// What a double-tap zooms to. Roughly matches Google Photos — enough to
  /// read detail in one tap, not so far that you lose your place.
  static const double _doubleTapScale = 2.5;

  final TransformationController transform = TransformationController();
  final AnimationController _animation;
  Animation<Matrix4>? _tween;

  /// True once the photo is scaled past its fitted size.
  final ValueNotifier<bool> zoomed = ValueNotifier(false);

  /// True once the zoom is deep enough that a 1x-screen-pixels decode would
  /// look soft, so the page should swap to a 2x decode. Hysteresis (on above
  /// [_highResOnScale], off back at [_highResOffScale]) keeps a pinch hovering
  /// around the threshold from re-decoding on every frame; the page only
  /// rebuilds when this flips.
  final ValueNotifier<bool> highRes = ValueNotifier(false);

  static const double _highResOnScale = 1.5;
  static const double _highResOffScale = 1.05;

  void _syncZoomed() {
    final scale = transform.value.getMaxScaleOnAxis();
    final isZoomed = scale > 1.01;
    if (isZoomed != zoomed.value) zoomed.value = isZoomed;
    if (!highRes.value && scale > _highResOnScale) {
      highRes.value = true;
    } else if (highRes.value && scale <= _highResOffScale) {
      highRes.value = false;
    }
  }

  /// Toggles between fitted and [_doubleTapScale], keeping whatever is under
  /// [localPosition] roughly under the finger instead of always zooming into
  /// the middle of the photo.
  void toggleZoom(Offset localPosition) {
    final target = zoomed.value
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(
              -localPosition.dx * (_doubleTapScale - 1),
              -localPosition.dy * (_doubleTapScale - 1),
              0,
              1,
            )
            ..scaleByDouble(
              _doubleTapScale,
              _doubleTapScale,
              _doubleTapScale,
              1,
            ));
    _tween = Matrix4Tween(begin: transform.value, end: target).animate(
      CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic),
    );
    _animation.forward(from: 0);
  }

  void dispose() {
    _animation.dispose();
    transform.dispose();
    zoomed.dispose();
    highRes.dispose();
  }
}

/// A viewer screen's "the enclosing PageView should not page right now" flag,
/// true whenever either of two independent things is happening on the
/// current page: a photo is zoomed in (one-finger drags pan it instead of
/// flicking to the next item), or [ViewerChromeHost] is mid swipe-to-dismiss
/// (see its `onDismissDragChanged` — a diagonal dismiss swipe needs the
/// PageView fully out of the way, not just out-competed, for the whole
/// gesture, including the instant it starts).
///
/// Pages report zoom state into this from their [PhotoZoomController],
/// including from `dispose()` — which runs mid-build — so writes are
/// deferred to the end of the frame and dropped if the screen itself is
/// already gone. Dismiss-drag state is reported from a raw pointer handler,
/// not mid-build, so it writes immediately — deferring it would leave one
/// stale frame where the PageView could still steal the gesture it's meant
/// to freeze out of.
class ViewerZoomLock extends ValueNotifier<bool> {
  ViewerZoomLock() : super(false);

  bool _disposed = false;
  bool _zoomed = false;
  bool _dismissDragging = false;

  void report(bool isZoomed) {
    if (_disposed) return;
    _zoomed = isZoomed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final next = _zoomed || _dismissDragging;
      if (value != next) value = next;
    });
  }

  void reportDragging(bool active) {
    if (_disposed) return;
    _dismissDragging = active;
    final next = _zoomed || _dismissDragging;
    if (value != next) value = next;
  }

  /// Physics for the PageView: frozen while zoomed in or mid dismiss-drag.
  ScrollPhysics? get physics =>
      value ? const NeverScrollableScrollPhysics() : null;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
