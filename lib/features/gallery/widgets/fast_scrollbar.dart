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

  double _fraction = 0;
  bool _dragging = false;
  bool _visible = false;
  Timer? _hideTimer;

  /// Track geometry captured on the last build — drag math needs it and the
  /// gesture callbacks run outside the LayoutBuilder.
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
    super.dispose();
  }

  void _onScroll() {
    if (_dragging) return; // the drag itself drives the position
    final position = widget.controller.positions.length == 1
        ? widget.controller.position
        : null;
    if (position == null || position.maxScrollExtent <= 0) return;
    setState(() {
      _fraction = (position.pixels / position.maxScrollExtent).clamp(0.0, 1.0);
      _visible = true;
    });
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_fadeAfter, () {
      if (mounted && !_dragging) setState(() => _visible = false);
    });
  }

  void _jumpTo(double fraction) {
    if (widget.controller.positions.length != 1) return;
    final position = widget.controller.position;
    if (position.maxScrollExtent <= 0) return;
    position.jumpTo(fraction * position.maxScrollExtent);
  }

  void _onDragStart(DragStartDetails _) {
    _hideTimer?.cancel();
    setState(() {
      _dragging = true;
      _visible = true;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final travel = _trackExtent - _thumbHeight;
    if (travel <= 0) return;
    setState(() {
      _fraction = (_fraction + details.delta.dy / travel).clamp(0.0, 1.0);
    });
    _jumpTo(_fraction);
  }

  void _onDragEnd(DragEndDetails _) {
    setState(() => _dragging = false);
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _trackExtent = constraints.maxHeight - widget.topInset - widget.bottomInset;
        final travel = _trackExtent - _thumbHeight;
        final canScroll = widget.controller.hasClients &&
            widget.controller.positions.length == 1 &&
            widget.controller.position.maxScrollExtent > 0;
        final label = _dragging ? widget.labelForFraction?.call(_fraction) : null;

        return Stack(
          children: [
            widget.child,
            if (canScroll && travel > 0)
              Positioned(
                top: widget.topInset + _fraction * travel,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  // Untargetable while faded out, so an invisible handle can't
                  // swallow taps meant for the photo underneath it.
                  child: IgnorePointer(
                    ignoring: !_visible,
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
                          child: _Thumb(active: _dragging),
                        ),
                      ],
                    ),
                  ),
                ),
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
        borderRadius: BorderRadius.circular(_FastScrollbarState._thumbWidth / 2),
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
