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
/// - Tap toggles floating semi-transparent buttons over the media (back top
///   left, an action row at the bottom) — no new window, just show/hide.
/// - Swipe up smoothly grows an info panel from the bottom while the media
///   shrinks to make room, tracking the finger 1:1 and settling with a short
///   animation on release — not a modal, part of the same screen.
class ViewerPageChrome extends StatefulWidget {
  const ViewerPageChrome({
    super.key,
    required this.child,
    required this.actions,
    required this.infoBuilder,
    this.onBack,
    this.gestureDisabled,
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

  @override
  State<ViewerPageChrome> createState() => _ViewerPageChromeState();
}

class _ViewerPageChromeState extends State<ViewerPageChrome>
    with SingleTickerProviderStateMixin {
  static const _maxPanelExtent = 320.0;

  bool _chromeVisible = true;
  double _panelExtent = 0;
  late final AnimationController _snapController;
  Animation<double>? _snapAnimation;

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

  void _onTap() {
    if (_panelExtent > 0) {
      _snapTo(0);
    } else {
      setState(() => _chromeVisible = !_chromeVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final panelOpenFraction = (_panelExtent / _maxPanelExtent).clamp(0.0, 1.0);
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: widget.gestureDisabled ?? _neverDisabled,
                builder: (context, disabled, child) => GestureDetector(
                  onTap: disabled ? null : _onTap,
                  onVerticalDragUpdate: disabled ? null : _onVerticalDragUpdate,
                  onVerticalDragEnd: disabled ? null : _onVerticalDragEnd,
                  child: child,
                ),
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
        Positioned(
          top: safeTop + 8,
          left: 8,
          child: AnimatedOpacity(
            opacity: _panelExtent == 0 ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: _FloatingCircleButton(
              icon: Icons.arrow_back,
              onTap: widget.onBack ?? () => Navigator.of(context).pop(),
            ),
          ),
        ),
        if (widget.actions.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16 + safeBottom,
            child: IgnorePointer(
              ignoring: !_chromeVisible || _panelExtent > 0,
              child: AnimatedOpacity(
                opacity: (_chromeVisible && _panelExtent == 0) ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [for (final a in widget.actions) _FloatingAction(action: a)],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _FloatingCircleButton extends StatelessWidget {
  const _FloatingCircleButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onTap,
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
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
              child: Icon(action.icon, color: color, size: 22),
            ),
            const SizedBox(height: 4),
            Text(action.label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
