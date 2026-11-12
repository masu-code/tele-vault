import 'dart:async';
import 'package:flutter/material.dart';

/// A large, easy-to-grab scroll handle pinned to the right edge, in the vein
/// of Google Photos'.
///
/// Flutter's stock [Scrollbar] thumb is a few pixels wide and shrinks as the
/// list grows — on a timeline thousands of items long it becomes a sliver
/// that's almost impossible to catch with a thumb. This keeps a fixed,
/// finger-sized target regardless of list length, fades out when idle so it
/// doesn't sit on top of the photos, and shows a date bubble while dragging
/// so you can aim at a month instead of scrubbing blind.
class FastScrollbar extends StatefulWidget {
  const FastScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.labelForFraction,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  final ScrollController controller;
  final Widget child;

  /// Bubble text for a position 0..1 through the scrollable, or null for no
  /// bubble. Called on every drag frame, so keep it cheap.
  final String? Function(double fraction)? labelForFraction;

  /// Keeps the track clear of chrome drawn over the list (the floating
  /// header at the top, the nav bar at the bottom).
  final double topInset;
  final double bottomInset;

  @override
  State<FastScrollbar> createState() => _FastScrollbarState();
}

class _FastScrollbarState extends State<FastScrollbar> {
  static const double _thumbHeight = 52;
  static const double _thumbWidth = 44;
  static const Duration _fadeAfter = Duration(milliseconds: 1200);

  // Scroll-driven state lives in ValueNotifiers, not setState — a fling
  // fires the scroll listener every frame, and setState here used to rerun
  // the LayoutBuilder below, forcing a full relayout of widget.child (the
  // entire grid) on every one of those frames. That's the actual cause of
  // the stutter/teleporting during a fast fling: real work competing with
  // Flutter's own scroll physics for the same frame budget, on top of
  // whatever the fling was already doing. A ValueListenableBuilder scoped to
  // just the thumb rebuilds only that small overlay, leaving the grid's own
  // layout completely undisturbed by the scroll position ticking.
  final ValueNotifier<double> _fraction = ValueNotifier(0);
  final ValueNotifier<bool> _visible = ValueNotifier(false);
  final ValueNotifier<bool> _dragging = ValueNotifier(false);
  late final Listenable _thumbListenable = Listenable.merge([
    _fraction,
    _visible,
    _dragging,
  ]);
  Timer? _hideTimer;

  /// Track geometry captured on the last layout — drag math needs it and the
  /// gesture callbacks run outside the LayoutBuilder. Only changes when this
  /// widget's own size does (rotation/window resize), since nothing here
  /// calls setState on scroll/drag anymore.
  double _trackExtent = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(FastScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onScroll);
    _fraction.dispose();
    _visible.dispose();
    _dragging.dispose();
    super.dispose();
  }

  /// True once [position] has an established viewport/content size to
  /// measure against. `ScrollPosition.maxScrollExtent` asserts on this
  /// internally in debug mode but null-checks a not-yet-set private field
  /// in release/profile — accessing it beforehand (e.g. right as a
  /// scrollable is first inserted, before its first layout) crashes with
  /// "Null check operator used on a null value" instead of the assert's
  /// friendlier message. `hasClients`/`positions.length == 1` alone don't
  /// cover this: a position can have a client attached before it's been
  /// through a layout pass.
  bool _hasMeasuredExtent(ScrollPosition position) =>
      position.hasContentDimensions;

  void _onScroll() {
    if (_dragging.value) return; // the drag itself drives the position
    final position = widget.controller.positions.length == 1
        ? widget.controller.position
        : null;
    if (position == null ||
        !_hasMeasuredExtent(position) ||
        position.maxScrollExtent <= 0) {
      return;
    }
    _fraction.value = (position.pixels / position.maxScrollExtent).clamp(
      0.0,
      1.0,
    );
    _visible.value = true;
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_fadeAfter, () {
      if (mounted && !_dragging.value) _visible.value = false;
    });
  }

  void _jumpTo(double fraction) {
    if (widget.controller.positions.length != 1) return;
    final position = widget.controller.position;
    if (!_hasMeasuredExtent(position) || position.maxScrollExtent <= 0) return;
    position.jumpTo(fraction * position.maxScrollExtent);
  }

  void _onDragStart(DragStartDetails _) {
    _hideTimer?.cancel();
    _dragging.value = true;
    _visible.value = true;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final travel = _trackExtent - _thumbHeight;
    if (travel <= 0) return;
    _fraction.value = (_fraction.value + details.delta.dy / travel).clamp(
      0.0,
      1.0,
    );
    _jumpTo(_fraction.value);
  }

  void _onDragEnd(DragEndDetails _) {
    _dragging.value = false;
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _trackExtent =
            constraints.maxHeight - widget.topInset - widget.bottomInset;
        final travel = _trackExtent - _thumbHeight;

        return Stack(
          children: [
            widget.child,
            if (travel > 0)
              ListenableBuilder(
                listenable: _thumbListenable,
                builder: (context, _) {
                  final canScroll =
                      widget.controller.hasClients &&
                      widget.controller.positions.length == 1 &&
                      _hasMeasuredExtent(widget.controller.position) &&
                      widget.controller.position.maxScrollExtent > 0;
                  if (!canScroll) return const SizedBox.shrink();
                  final dragging = _dragging.value;
                  final label = dragging
                      ? widget.labelForFraction?.call(_fraction.value)
                      : null;

                  return Positioned(
                    top: widget.topInset + _fraction.value * travel,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: _visible.value ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      // Untargetable while faded out, so an invisible handle
                      // can't swallow taps meant for the photo underneath it.
                      child: IgnorePointer(
                        ignoring: !_visible.value,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            if (label != null) _DateBubble(text: label),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onVerticalDragStart: _onDragStart,
                              onVerticalDragUpdate: _onDragUpdate,
                              onVerticalDragEnd: _onDragEnd,
                              child: _Thumb(active: dragging),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _FastScrollbarState._thumbWidth,
      height: _FastScrollbarState._thumbHeight,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: active ? const Color(0xFF4A4A4E) : const Color(0xCC38383C),
        borderRadius: BorderRadius.circular(
          _FastScrollbarState._thumbWidth / 2,
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.keyboard_arrow_up, size: 20, color: Colors.white),
          Icon(Icons.keyboard_arrow_down, size: 20, color: Colors.white),
        ],
      ),
    );
  }
}

class _DateBubble extends StatelessWidget {
  const _DateBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xE6202024),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
