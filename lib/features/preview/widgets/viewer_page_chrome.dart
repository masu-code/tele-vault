import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Shared no-op listenable for viewers that don't pass [ViewerPageChrome.gestureDisabled]
/// (e.g. video pages) — avoids allocating a new never-changing notifier per build.
final ValueNotifier<bool> _neverDisabled = ValueNotifier(false);

/// One floating action in the bottom row (icon + small label), shown over the
/// media when the chrome is visible. Null [onTap] renders it disabled/dim —
/// used for "already on device" style informational states.
class ViewerAction {
  const ViewerAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
}

/// Shared chrome for the full-screen media viewers (cloud and local):
/// - Tap zones: the outer quarter on each side steps to the previous/next
///   item, the middle toggles the floating controls.
/// - Optional double-tap on the outer quarters (video only) seeks.
/// - Swipe up smoothly grows an info panel from the bottom while the media
///   shrinks to make room, tracking the finger 1:1 and settling with a short
///   animation on release — not a modal, part of the same screen.
/// - Top and bottom gradient scrims keep the controls legible over any
///   content, including a photo that's white edge to edge.
class ViewerPageChrome extends StatefulWidget {
  const ViewerPageChrome({
    super.key,
    required this.child,
    required this.actions,
    required this.infoBuilder,
    this.onBack,
    this.gestureDisabled,
    this.onPrevious,
    this.onNext,
    this.onSeekBackward,
    this.onSeekForward,
  });

  /// The full-bleed media content (image or video).
  final Widget child;

  /// Bottom action row shown while the chrome is visible and the info panel
  /// is closed. Empty list hides the row entirely.
  final List<ViewerAction> actions;

  /// Builds the info panel's content (title, date, size, ...). Only built
  /// while the panel is at least partly open.
  final WidgetBuilder infoBuilder;

  /// Defaults to popping the route.
  final VoidCallback? onBack;

  /// While true, the tap-to-toggle and swipe-up-for-info gestures are
  /// suppressed. Pass the zoomed state of an InteractiveViewer child here —
  /// its own pan/scale recognizer competes with this widget's vertical-drag
  /// recognizer for the same pointer, and when zoomed in the user's drag
  /// should always pan the image, never fight it for the info panel.
  final ValueListenable<bool>? gestureDisabled;

  /// Single tap on the left/right quarter of the screen. Null disables that
  /// zone, and taps there fall through to the middle's toggle behaviour.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// Double tap on the left/right quarter. Supplying either enables
  /// double-tap detection, which necessarily delays single taps slightly
  /// while the recognizer waits for a possible second tap — so only video
  /// pages pass these, leaving photo paging instant.
  final VoidCallback? onSeekBackward;
  final VoidCallback? onSeekForward;

  @override
  State<ViewerPageChrome> createState() => _ViewerPageChromeState();
}

class _ViewerPageChromeState extends State<ViewerPageChrome>
    with SingleTickerProviderStateMixin {
  static const _maxPanelExtent = 320.0;

  /// Fraction of the width on each edge that acts as a prev/next (and seek)
  /// zone. The middle half stays free for toggling the chrome.
  static const _edgeZone = 0.25;

  bool _chromeVisible = true;
  double _panelExtent = 0;
  late final AnimationController _snapController;
  Animation<double>? _snapAnimation;

  /// Live count of fingers currently touching the screen. A second pointer
  /// touching down means this is a pinch, not a tap/vertical-drag — disabling
  /// this widget's own gesture recognizers the instant that happens (rather
  /// than waiting for [widget.gestureDisabled], which only flips once the
  /// child's InteractiveViewer has *already* registered a scale) stops them
  /// from winning the gesture arena race against InteractiveViewer's scale
  /// recognizer in the first place — without this, starting a pinch could
  /// get eaten as a vertical drag before zooming ever had a chance to begin.
  int _activePointers = 0;

  /// Where the in-progress double tap landed. [GestureDetector.onDoubleTap]
  /// carries no position, so it has to be captured on the preceding down.
  Offset? _doubleTapPos;

  /// Brief "10s" bubble shown after a seek, and which side to show it on.
  String? _seekHint;
  bool _seekHintOnLeft = false;
  Timer? _seekHintTimer;

  @override
  void initState() {
    super.initState();
    _snapController = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
      ..addListener(() {
        if (_snapAnimation != null) setState(() => _panelExtent = _snapAnimation!.value);
      });
  }

  @override
  void dispose() {
    _seekHintTimer?.cancel();
    _snapController.dispose();
    super.dispose();
  }

  void _snapTo(double target, {double velocity = 0}) {
    _snapAnimation = Tween(begin: _panelExtent, end: target).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOut),
    );
    _snapController.forward(from: 0);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    _snapController.stop();
    setState(() {
      _panelExtent = (_panelExtent - details.delta.dy).clamp(0.0, _maxPanelExtent);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final open = velocity < -200 || (velocity <= 200 && _panelExtent > _maxPanelExtent / 2);
    _snapTo(open ? _maxPanelExtent : 0, velocity: velocity);
  }

  /// Which edge zone [dx] falls in, given the content width: -1 left, 1
  /// right, 0 middle.
  int _zoneFor(double dx, double width) {
    if (width <= 0) return 0;
    if (dx < width * _edgeZone) return -1;
    if (dx > width * (1 - _edgeZone)) return 1;
    return 0;
  }

  void _onTapUp(TapUpDetails details, double width) {
    // An open info panel swallows the tap to close, wherever it landed —
    // paging out from under a half-open panel would leave it stranded over
    // the next item's content.
    if (_panelExtent > 0) {
      _snapTo(0);
      return;
    }
    switch (_zoneFor(details.localPosition.dx, width)) {
      case -1 when widget.onPrevious != null:
        widget.onPrevious!();
      case 1 when widget.onNext != null:
        widget.onNext!();
      default:
        setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  void _onDoubleTap(double width) {
    final pos = _doubleTapPos;
    if (pos == null) return;
    switch (_zoneFor(pos.dx, width)) {
      case -1 when widget.onSeekBackward != null:
        widget.onSeekBackward!();
        _showSeekHint('10s', onLeft: true);
      case 1 when widget.onSeekForward != null:
        widget.onSeekForward!();
        _showSeekHint('10s', onLeft: false);
    }
  }

  void _showSeekHint(String text, {required bool onLeft}) {
    _seekHintTimer?.cancel();
    setState(() {
      _seekHint = text;
      _seekHintOnLeft = onLeft;
    });
    _seekHintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekHint = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final panelOpenFraction = (_panelExtent / _maxPanelExtent).clamp(0.0, 1.0);
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final wantsDoubleTap =
        widget.onSeekBackward != null || widget.onSeekForward != null;

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: widget.gestureDisabled ?? _neverDisabled,
                builder: (context, disabledByZoom, child) {
                  final disabled = disabledByZoom || _activePointers >= 2;
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      return Listener(
                        onPointerDown: (_) => setState(() => _activePointers++),
                        onPointerUp: (_) => setState(
                            () => _activePointers = (_activePointers - 1).clamp(0, 10)),
                        onPointerCancel: (_) => setState(
                            () => _activePointers = (_activePointers - 1).clamp(0, 10)),
                        child: GestureDetector(
                          onTapUp: disabled ? null : (d) => _onTapUp(d, width),
                          onDoubleTapDown: disabled || !wantsDoubleTap
                              ? null
                              : (d) => _doubleTapPos = d.localPosition,
                          onDoubleTap: disabled || !wantsDoubleTap
                              ? null
                              : () => _onDoubleTap(width),
                          onVerticalDragUpdate: disabled ? null : _onVerticalDragUpdate,
                          onVerticalDragEnd: disabled ? null : _onVerticalDragEnd,
                          child: child,
                        ),
                      );
                    },
                  );
                },
                child: widget.child,
              ),
            ),
            if (_panelExtent > 0)
              Container(
                width: double.infinity,
                height: _panelExtent,
                color: Colors.black,
                padding: EdgeInsets.only(bottom: safeBottom),
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Opacity(
                    opacity: panelOpenFraction,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: Container(
                              width: 36,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Builder(builder: widget.infoBuilder),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),

        if (_seekHint != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: _seekHintOnLeft ? Alignment.centerLeft : Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: _SeekHint(
                    text: _seekHint!,
                    forward: !_seekHintOnLeft,
                  ),
                ),
              ),
            ),
          ),

        // Top scrim + back button. The scrim is what makes a white icon
        // readable over a white photo — see the bottom bar for the same idea.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !_chromeVisible || _panelExtent > 0,
            child: AnimatedOpacity(
              opacity: (_chromeVisible && _panelExtent == 0) ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Container(
                padding: EdgeInsets.only(top: safeTop + 8, bottom: 24, left: 8, right: 8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: widget.onBack ?? () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ),
        ),

        if (widget.actions.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_chromeVisible || _panelExtent > 0,
              child: AnimatedOpacity(
                opacity: (_chromeVisible && _panelExtent == 0) ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  padding: EdgeInsets.only(top: 32, bottom: safeBottom + 12),
                  // A single scrim behind the whole row, rather than a puck
                  // per icon: individual circles still left the labels
                  // unreadable, and over a bright photo the row as a whole
                  // disappeared into the background.
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Color(0xD9000000),
                        Color(0x99000000),
                        Color(0x00000000),
                      ],
                      stops: [0.0, 0.55, 1.0],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [for (final a in widget.actions) _FloatingAction(action: a)],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SeekHint extends StatelessWidget {
  const _SeekHint({required this.text, required this.forward});
  final String text;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: const BoxDecoration(
        color: Color(0x99000000),
        shape: BoxShape.circle,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            forward ? Icons.fast_forward : Icons.fast_rewind,
            color: Colors.white,
            size: 26,
          ),
          const SizedBox(height: 2),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _FloatingAction extends StatelessWidget {
  const _FloatingAction({required this.action});
  final ViewerAction action;

  @override
  Widget build(BuildContext context) {
    final color = action.onTap == null ? Colors.white38 : (action.color ?? Colors.white);
    return InkWell(
      onTap: action.onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(action.icon, color: color, size: 24),
            const SizedBox(height: 6),
            Text(
              action.label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
