import 'dart:async';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

/// Owns a photo page's pan/zoom state: the `photo_view` [PhotoViewController]
/// (scale + position), the "is zoomed in" flag the surrounding gestures key
/// off, and the animated double-tap zoom.
///
/// Pinch and pan are `photo_view`'s own gesture recognizer; this class only
/// reads its result and drives the double-tap, which [ViewerChromeHost]
/// detects (it owns every tap on the viewer) and `photo_view` cannot anchor on
/// the tapped point.
///
/// The page builds its [PhotoView] with a fixed child size (the viewport), so
/// [scale] is relative to the fitted photo, 1.0 = fitted, regardless of which
/// decode (thumbnail, 1x, 2x) is on screen. That is what lets the thumbnail be
/// zoomed before the full-resolution file arrives and keeps the zoom and pan
/// untouched when it does.
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
    // The stream, not addIgnorableListener: photo_view's own snap-back
    // animations (pinched below 1x or past [maxScale]) update the scale
    // "invisibly", which only the stream reports.
    _subscription = view.outputStateStream.listen((_) => _syncZoomed());
    _animation.addListener(_onAnimationTick);
  }

  /// Fitted size. Pinching below it springs back.
  static const double minScale = 1.0;

  /// Deepest zoom, relative to the fitted size.
  static const double maxScale = 5.0;

  /// What a double-tap zooms to. Roughly matches Google Photos — enough to
  /// read detail in one tap, not so far that you lose your place.
  static const double _doubleTapScale = 2.5;

  /// Scale and position (offset of the photo's centre from the viewport's
  /// centre) of the page's [PhotoView].
  final PhotoViewController view = PhotoViewController();

  /// Passed to the page's [PhotoView] together with [noDoubleTapCycle], so
  /// photo_view's built-in double-tap never fights [toggleZoom].
  final PhotoViewScaleStateController scaleState =
      PhotoViewScaleStateController();

  /// The page's viewport, set by the page on layout. [toggleZoom] needs its
  /// centre to keep the tapped point under the finger.
  Size viewportSize = Size.zero;

  final AnimationController _animation;
  late final StreamSubscription<PhotoViewControllerValue> _subscription;
  Tween<double>? _scaleTween;
  Tween<Offset>? _positionTween;

  /// Current scale relative to the fitted photo (null before photo_view's
  /// first layout, which means fitted).
  double get scale => view.scale ?? minScale;

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
    if (_disposed) return;
    final scale = this.scale;
    final isZoomed = scale > 1.01;
    if (isZoomed != zoomed.value) zoomed.value = isZoomed;
    if (!highRes.value && scale > _highResOnScale) {
      highRes.value = true;
    } else if (highRes.value && scale <= _highResOffScale) {
      highRes.value = false;
    }
  }

  bool _disposed = false;

  /// For [PhotoView.scaleStateCycle]: never moves to another scale state, so
  /// photo_view's own double-tap recognizer is a no-op and [toggleZoom]
  /// (driven by [ViewerChromeHost]) is the only double-tap zoom.
  static PhotoViewScaleState noDoubleTapCycle(PhotoViewScaleState actual) =>
      actual;

  /// Toggles between fitted and [_doubleTapScale], keeping whatever is under
  /// [localPosition] (viewport coordinates) under the finger instead of
  /// always zooming into the middle of the photo.
  void toggleZoom(Offset localPosition) {
    final double targetScale;
    final Offset targetPosition;
    if (zoomed.value) {
      targetScale = minScale;
      targetPosition = Offset.zero;
    } else {
      // photo_view scales about the viewport centre and then translates by
      // `position`; a point `d` from the centre lands at `position + s*d`,
      // so `position = -d * (s - 1)` keeps it where it was. Always inside
      // photo_view's pan bounds for a point inside the viewport.
      final fromCentre = localPosition - viewportSize.center(Offset.zero);
      targetScale = _doubleTapScale;
      targetPosition = -fromCentre * (_doubleTapScale - 1);
    }
    _scaleTween = Tween(begin: scale, end: targetScale);
    _positionTween = Tween(begin: view.position, end: targetPosition);
    _animation.forward(from: 0);
  }

  void _onAnimationTick() {
    final scaleTween = _scaleTween;
    final positionTween = _positionTween;
    if (scaleTween == null || positionTween == null) return;
    final t = Curves.easeOutCubic.transform(_animation.value);
    view.updateMultiple(
      scale: scaleTween.transform(t),
      position: positionTween.transform(t),
    );
  }

  void dispose() {
    _disposed = true;
    _subscription.cancel();
    _animation.dispose();
    view.dispose();
    scaleState.dispose();
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
