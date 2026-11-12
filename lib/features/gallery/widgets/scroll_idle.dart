import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Tracks whether the [CustomScrollView] it wraps is currently moving —
/// being dragged, or still coasting from a fling — versus fully at rest.
///
/// [GalleryTile] uses the exposed [idle] notifier to decide when it's safe
/// to start decoding its thumbnail. A per-tile fixed delay alone isn't
/// enough: during one long, continuous fast fling, any tile that happens to
/// stay on screen longer than that delay would start decoding anyway, right
/// as the fling itself needs every frame it can get — that's what turned a
/// hard downward fling into stutter and, eventually, an ANR. Telegram and
/// Google Photos don't decode anything until the list actually stops
/// moving; gating on [idle] (driven by real [ScrollNotification]s, not a
/// guess) reproduces that instead of approximating it with a timer.
class ScrollIdleTracker extends StatefulWidget {
  const ScrollIdleTracker({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollIdleTracker> createState() => _ScrollIdleTrackerState();
}

class _ScrollIdleTrackerState extends State<ScrollIdleTracker> {
  final ValueNotifier<bool> _idle = ValueNotifier(true);

  @override
  void dispose() {
    _idle.dispose();
    super.dispose();
  }

  bool _onNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _idle.value = false;
    } else if (notification is ScrollEndNotification) {
      _idle.value = true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: ScrollIdle(idle: _idle, child: widget.child),
    );
  }
}

/// Exposes the [ValueListenable<bool>] a [ScrollIdleTracker] ancestor
/// maintains — see that class for why this exists.
class ScrollIdle extends InheritedWidget {
  const ScrollIdle({super.key, required this.idle, required super.child});

  final ValueListenable<bool> idle;

  static ValueListenable<bool>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScrollIdle>()?.idle;

  @override
  bool updateShouldNotify(ScrollIdle oldWidget) => idle != oldWidget.idle;
}
