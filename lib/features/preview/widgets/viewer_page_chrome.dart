import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout, VelocityTracker;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Exposes [ViewerChromeHost]'s show/hide state to descendants — specifically
/// the video controls built by [videoSeekControls], so a video's seek bar
/// and play/pause button show and hide in lockstep with the same tap that
/// shows and hides the top bar and action row, instead of being a second,
/// independent toggle.
class ViewerChromeVisibility extends InheritedWidget {
  const ViewerChromeVisibility({
    super.key,
    required this.visible,
    required super.child,
  });

  final ValueListenable<bool> visible;

  static ValueListenable<bool>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ViewerChromeVisibility>()
      ?.visible;

  @override
  bool updateShouldNotify(ViewerChromeVisibility oldWidget) =>
      visible != oldWidget.visible;
}

/// The pointers currently claimed by a [ViewerTapShield], owned by the
/// enclosing [ViewerChromeHost].
class _ViewerTapShieldScope extends InheritedWidget {
  const _ViewerTapShieldScope({required this.claimed, required super.child});

  final Set<int> claimed;

  @override
  bool updateShouldNotify(_ViewerTapShieldScope oldWidget) =>
      claimed != oldWidget.claimed;
}

/// Wrap an interactive control (seek bar, buttons) drawn over the viewer's
/// media so a tap on it is the control's alone: [ViewerChromeHost] listens to
/// raw pointers over the whole page and would otherwise also read that tap as
/// "page to previous/next" (edge zones) or "toggle the chrome".
///
/// A raw [Listener] is outside the gesture arena, so nothing the control does
/// can stop the host from seeing the pointer; instead the shield registers its
/// pointer id with the host on pointer down (inner listeners run before outer
/// ones), and the host skips its tap handling for that pointer. Outside a
/// [ViewerChromeHost] it does nothing.
class ViewerTapShield extends StatelessWidget {
  const ViewerTapShield({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final claimed = context
        .getInheritedWidgetOfExactType<_ViewerTapShieldScope>()
        ?.claimed;
    return Listener(
      onPointerDown: claimed == null ? null : (e) => claimed.add(e.pointer),
      child: child,
    );
  }
}

/// The viewer's single full-screen state (landscape + hidden system bars),
/// shared by every video page's button so neighbouring pages in the PageView
/// never disagree about it. Owned by [ViewerChromeHost], which restores
/// portrait / edge-to-edge / unlocked orientations when the viewer goes away.
class ViewerFullscreenController extends ValueNotifier<bool> {
  ViewerFullscreenController() : super(false);

  // Platform calls run strictly one after another, so a fast double tap
  // cannot interleave an enter with an exit and leave the screen rotated.
  Future<void> _chain = Future<void>.value();

  void toggle() {
    value = !value;
    _apply(value);
  }

  /// Puts orientation and system bars back if full screen is on. Does not
  /// notify: meant for dispose.
  void restoreIfOn() {
    if (value) _apply(false);
  }

  void _apply(bool on) {
    _chain = _chain
        .then((_) => on ? _enter() : _exit())
        .catchError((Object _) {});
  }

  static Future<void> _enter() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  static Future<void> _exit() async {
    await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Back to "follow the app's default" once portrait has been applied.
    await SystemChrome.setPreferredOrientations(const []);
  }
}

/// Provides the viewer's [ViewerFullscreenController] to the video controls.
class ViewerFullscreen extends InheritedWidget {
  const ViewerFullscreen({
    super.key,
    required this.controller,
    required super.child,
  });

  final ViewerFullscreenController controller;

  static ViewerFullscreenController? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<ViewerFullscreen>()
      ?.controller;

  @override
  bool updateShouldNotify(ViewerFullscreen oldWidget) =>
      controller != oldWidget.controller;
}

/// One floating action in the bottom row (icon + small label), shown over the
/// media when the chrome is visible. Null [onTap] renders it non-interactive
/// — used for "already on device" style informational states. It's still
/// drawn at full brightness: it means "done", not "unavailable", so it
/// shouldn't read as greyed-out/disabled.
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

Widget _emptyInfoBuilder(BuildContext context) => const SizedBox.shrink();

/// What [ViewerChromeHost] needs from whichever page is currently showing —
/// its action row, its info panel content, and (for a photo page) its
/// double-tap-zoom callback and zoomed state, or (for a video page) its
/// double-tap-seek callbacks. A page reports one of these up to the host
/// every time it builds; see [ViewerChromeHost.descriptor].
@immutable
class ViewerChromeDescriptor {
  const ViewerChromeDescriptor({
    this.actions = const [],
    this.infoBuilder = _emptyInfoBuilder,
    this.onDoubleTapZoom,
    this.zoomed,
    this.onSeekBackward,
    this.onSeekForward,
  });

  /// Bottom action row shown while the chrome is visible and the info panel
  /// is closed. Empty hides the row entirely.
  final List<ViewerAction> actions;

  /// Builds the info panel's content (title, date, size, ...). Only built
  /// while the panel is at least partly open.
  final WidgetBuilder infoBuilder;

  /// Double tap anywhere, to zoom in/out around the tapped point (photo
  /// pages only).
  final void Function(Offset localPosition)? onDoubleTapZoom;

  /// Whether the current photo page is zoomed past its fitted size. An edge
  /// tap means "I'm looking at this corner" while zoomed, not "page to the
  /// next one".
  final ValueListenable<bool>? zoomed;

  /// Double tap in the left/right half, to seek (video pages only).
  final VoidCallback? onSeekBackward;
  final VoidCallback? onSeekForward;
}

/// Height of the bottom action-row scrim, excluding the safe-area inset
/// added on top of it. [videoSeekControls] needs this to lift the video's
/// own seek bar above the action row instead of sitting underneath its
/// blurred scrim, invisible.
const kViewerBottomBarHeight = 108.0;

/// The full-screen viewer's chrome and gestures — one instance per *screen*,
/// wrapping the [PageView] itself rather than living inside each page.
///
/// This used to be `ViewerPageChrome`, built fresh by every page (photo,
/// video, cloud, local) as its own child of the PageView. That meant the
/// widget doing gesture recognition was torn down and rebuilt by the
/// PageView on every page change, which is exactly the wrong lifecycle for
/// gestures that need to keep working *through* a page transition: tapping
/// the edge repeatedly to page through several photos fast, or swiping down
/// to dismiss the instant after a swipe-to-next-photo, both landed on
/// whatever page instance happened to exist at that moment, which wasn't
/// always ready. Living here instead — a single instance for the screen's
/// whole lifetime, wrapping the PageView as a sibling rather than a child —
/// means the layer listening for gestures never gets rebuilt by a page
/// transition in the first place.
///
/// What still varies per page (the action row, the info panel's content,
/// zoom/seek) is supplied via [descriptor], which whichever page is
/// currently building reports itself into — see [ViewerChromeDescriptor].
///
/// - Tap zones: a narrow strip on each edge steps to the previous/next item;
///   everywhere else toggles the floating controls.
/// - Double-tap in that same edge strip (video only) seeks; double-tap
///   anywhere (photo only) zooms.
/// - Swipe up smoothly grows an info panel from the bottom while the media
///   shrinks to make room, tracking the finger 1:1 and settling with a short
///   animation on release — not a modal, part of the same screen.
/// - Top and bottom gradient scrims keep the controls legible over any
///   content, including a photo that's white edge to edge.
class ViewerChromeHost extends StatefulWidget {
  const ViewerChromeHost({
    super.key,
    required this.child,
    required this.descriptor,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.onDismissDragChanged,
  });

  /// The PageView (or whatever paged content sits below the chrome).
  final Widget child;

  /// The currently-showing page's actions/info/zoom/seek — updated by the
  /// screen as its current index changes (each page reports itself in when
  /// it builds; see the class doc).
  final ValueListenable<ViewerChromeDescriptor> descriptor;

  /// Defaults to popping the route.
  final VoidCallback? onBack;

  /// Single tap on the left/right edge strip. Null disables that zone, and
  /// taps there fall through to the toggle behaviour.
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  /// Called with `true` the instant a raw pointer's movement resolves as a
  /// vertical (dismiss/panel) drag, and `false` when that drag ends —
  /// intended to freeze the PageView's own paging for the gesture's whole
  /// duration (it must not even try to claim it, not just lose an arena
  /// contest for it). See [_onPointerMove].
  final ValueChanged<bool>? onDismissDragChanged;

  @override
  State<ViewerChromeHost> createState() => _ViewerChromeHostState();
}

class _ViewerChromeHostState extends State<ViewerChromeHost>
    with SingleTickerProviderStateMixin {
  static const _maxPanelExtent = 320.0;

  /// Fraction of the width on each edge that acts as a prev/next (and seek)
  /// zone. Deliberately narrow — a wide zone made ordinary taps-to-toggle
  /// page by accident.
  static const _edgeZone = 0.12;

  /// How far apart two taps can land and still count as one double-tap.
  static const _doubleTapSlop = 60.0;

  /// How far past a full downward drag counts as "let go of it" rather than
  /// "snap back" — matched against either distance or release velocity, the
  /// same two-way check Google Photos/Instagram use for swipe-to-dismiss.
  static const _dismissDistanceThreshold = 120.0;
  static const _dismissVelocityThreshold = 800.0;

  bool _chromeVisible = true;
  // Mirrors _chromeVisible for ViewerChromeVisibility below — kept as a
  // plain ValueNotifier (not a setState-driven field) so a video's controls
  // can listen to just this, without needing this whole widget to be an
  // InheritedWidget itself.
  final ValueNotifier<bool> _chromeVisibleNotifier = ValueNotifier(true);
  final ViewerFullscreenController _fullscreen = ViewerFullscreenController();

  /// Pointers claimed by a [ViewerTapShield] since they went down; cleared on
  /// up/cancel. Those never count as a tap on the viewer itself.
  final Set<int> _shieldedPointers = {};
  double _panelExtent = 0;
  double _dismissOffset = 0;
  late final AnimationController _snapController;
  Animation<double>? _snapAnimation;
  bool _snapTargetsDismiss = false;

  /// Live count of fingers currently touching the screen. A second pointer
  /// touching down means this is a pinch, not a tap/vertical-drag — bailing
  /// out of whatever pan we were tracking the instant that happens (rather
  /// than waiting for the current page to report itself zoomed, which only
  /// flips once its InteractiveViewer has *already* registered a scale)
  /// stops it from fighting InteractiveViewer's scale gesture for the same
  /// pointers.
  int _activePointers = 0;

  // --- Raw pointer-driven pan/tap tracking ---------------------------------
  //
  // This used to be a GestureDetector with competing onTapUp/onVerticalDrag*
  // recognizers, sitting inside each page, inside the PageView. Two things
  // about that turned out to cost real responsiveness, neither fixable by
  // tuning the recognizers, and a third only fixable by moving this widget
  // out of the PageView entirely (see the class doc):
  // (1) Flutter's TapGestureRecognizer, when it shares an arena with a
  // VerticalDragGestureRecognizer (ours) AND an ancestor
  // HorizontalDragGestureRecognizer (the PageView's), doesn't resolve a tap
  // the instant the finger lifts — it waits for the arena to settle, which
  // in practice added a very similar lag to the kDoubleTapTimeout wait this
  // file used to have on purpose (see the old _onTapUp). (2) our
  // VerticalDragGestureRecognizer only ever got a chance to compete for a
  // gesture in the first place if it happened to look "vertical enough" to
  // beat the PageView's own recognizer to accepting.
  //
  // Tracking pointers directly sidesteps (1) and (2): a raw Listener never
  // enters the gesture arena, so nothing here is racing the PageView for
  // anything. A tap resolves the instant the finger lifts having not moved
  // past [_panSlop]. A drag's axis is decided by us, from the actual path
  // taken, the moment it clears that same small slop — and
  // [ViewerChromeHost.onDismissDragChanged] freezes the PageView's physics
  // (via ViewerZoomLock, shared at the screen level) synchronously in that
  // same callback.
  static const _panSlop = 8.0;

  int? _panPointer;
  Offset? _panStartPos;
  /// null = undecided, true = ours (dismiss/panel), false = the PageView's.
  bool? _panIsVertical;
  VelocityTracker? _velocityTracker;

  // Tracks the previous tap so a second one landing nearby in time counts as
  // a double-tap — see _onTap for why this no longer *delays* the single
  // tap's own action while it waits to find out.
  DateTime? _lastTapTime;
  Offset? _lastTapPos;

  /// Brief seek-amount bubble shown after a seek, and which side to show it on.
  String? _seekHint;
  bool _seekHintOnLeft = false;
  Timer? _seekHintTimer;

  @override
  void initState() {
    super.initState();
    _snapController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          if (_snapAnimation == null) return;
          setState(() {
            if (_snapTargetsDismiss) {
              _dismissOffset = _snapAnimation!.value;
            } else {
              _panelExtent = _snapAnimation!.value;
            }
          });
        });
    widget.descriptor.addListener(_onDescriptorChanged);
  }

  @override
  void didUpdateWidget(ViewerChromeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.descriptor != widget.descriptor) {
      oldWidget.descriptor.removeListener(_onDescriptorChanged);
      widget.descriptor.addListener(_onDescriptorChanged);
    }
  }

  @override
  void dispose() {
    widget.descriptor.removeListener(_onDescriptorChanged);
    _seekHintTimer?.cancel();
    _snapController.dispose();
    _chromeVisibleNotifier.dispose();
    _fullscreen.restoreIfOn();
    _fullscreen.dispose();
    super.dispose();
  }

  // The action row and info panel read widget.descriptor.value directly in
  // build(), so this only needs to trigger that rebuild.
  void _onDescriptorChanged() {
    if (mounted) setState(() {});
  }

  void _snapPanelTo(double target) {
    _snapTargetsDismiss = false;
    _snapAnimation = Tween(
      begin: _panelExtent,
      end: target,
    ).animate(CurvedAnimation(parent: _snapController, curve: Curves.easeOut));
    _snapController.forward(from: 0);
  }

  void _snapDismissTo(double target) {
    _snapTargetsDismiss = true;
    _snapAnimation = Tween(
      begin: _dismissOffset,
      end: target,
    ).animate(CurvedAnimation(parent: _snapController, curve: Curves.easeOut));
    _snapController.forward(from: 0);
  }

  void _applyVerticalDelta(double dy) {
    // Once the panel is fully closed, continuing to drag down switches to
    // dragging the whole viewer away instead — one continuous gesture can
    // flow from "close the panel" straight into "dismiss", the way Google
    // Photos does it, rather than those being two separate gestures.
    if (_dismissOffset > 0 || (_panelExtent <= 0 && dy > 0)) {
      setState(
        () =>
            _dismissOffset = (_dismissOffset + dy).clamp(0.0, double.infinity),
      );
    } else {
      setState(
        () => _panelExtent = (_panelExtent - dy).clamp(0.0, _maxPanelExtent),
      );
    }
  }

  void _finishVerticalDrag(double velocity) {
    if (_dismissOffset > 0) {
      if (_dismissOffset > _dismissDistanceThreshold ||
          velocity > _dismissVelocityThreshold) {
        (widget.onBack ?? () => Navigator.of(context).pop())();
      } else {
        _snapDismissTo(0);
      }
      return;
    }
    final open =
        velocity < -200 ||
        (velocity <= 200 && _panelExtent > _maxPanelExtent / 2);
    _snapPanelTo(open ? _maxPanelExtent : 0);
  }

  void _onPointerDown(PointerDownEvent event) {
    _activePointers++;
    if (_activePointers > 1) {
      // A second finger mid-pan means this just became a pinch — release
      // whatever we were tracking (and un-freeze paging if we'd frozen it)
      // so InteractiveViewer's scale gesture starts from a clean slate.
      if (_panIsVertical == true) widget.onDismissDragChanged?.call(false);
      _panPointer = null;
      _panIsVertical = null;
      return;
    }
    _panPointer = event.pointer;
    _panStartPos = event.localPosition;
    _panIsVertical = null;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
  }

  void _onPointerMove(PointerMoveEvent event) {
    // A drag that started on a shielded control (the seek bar) is the
    // control's, never a dismiss/panel drag.
    if (_shieldedPointers.contains(event.pointer)) return;
    if (event.pointer != _panPointer || _activePointers != 1) return;
    _velocityTracker?.addPosition(event.timeStamp, event.localPosition);

    // While the current page is zoomed, a one-finger move is
    // InteractiveViewer's to pan the photo with — we still track it (so a
    // real pan doesn't misfire as a tap on release below) but don't act on
    // the axis or drive dismiss/panel.
    if (_zoomedIn) return;

    if (_panIsVertical == null) {
      final total = event.localPosition - _panStartPos!;
      if (total.distance < _panSlop) return;
      // Generous toward vertical on purpose: a diagonal swipe-to-dismiss
      // shouldn't need to be a near-perfect vertical line to register, any
      // more than a real photo app would ask for one.
      _panIsVertical = total.dy.abs() > total.dx.abs() * 0.5;
      if (_panIsVertical == true) {
        _snapController.stop();
        widget.onDismissDragChanged?.call(true);
      }
    }
    if (_panIsVertical == true) _applyVerticalDelta(event.delta.dy);
  }

  void _onPointerUp(PointerUpEvent event) {
    _activePointers = (_activePointers - 1).clamp(0, 10);
    if (_shieldedPointers.remove(event.pointer)) {
      // Claimed by a control: not a tap on the viewer, so no paging/toggle.
      if (event.pointer == _panPointer) {
        _panPointer = null;
        _panIsVertical = null;
      }
      return;
    }
    if (event.pointer != _panPointer) return;
    final wasVertical = _panIsVertical;
    final startPos = _panStartPos!;
    _panPointer = null;
    _panIsVertical = null;

    if (wasVertical == true) {
      widget.onDismissDragChanged?.call(false);
      final vy = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0;
      _finishVerticalDrag(vy);
      return;
    }
    // Neither a vertical drag nor (if wasVertical == false) the PageView's
    // own horizontal swipe needs anything more from us. A tap is whatever's
    // left: the finger never moved past the slop in the first place.
    if ((event.localPosition - startPos).distance < _panSlop) {
      _onTap(event.localPosition, MediaQuery.sizeOf(context).width);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers = (_activePointers - 1).clamp(0, 10);
    _shieldedPointers.remove(event.pointer);
    if (event.pointer != _panPointer) return;
    if (_panIsVertical == true) widget.onDismissDragChanged?.call(false);
    _panPointer = null;
    _panIsVertical = null;
  }

  /// Which edge zone [dx] falls in, given the content width: -1 left, 1
  /// right, 0 middle.
  int _zoneFor(double dx, double width) {
    if (width <= 0) return 0;
    if (dx < width * _edgeZone) return -1;
    if (dx > width * (1 - _edgeZone)) return 1;
    return 0;
  }

  /// Which half [dx] falls in — left seeks backward, right seeks forward.
  /// Deliberately NOT the same narrow [_zoneFor] edge strip used for
  /// prev/next: an accidental double-tap is far less likely than an
  /// accidental single tap near an edge, so it can safely claim half the
  /// screen each side instead of a thin margin.
  int _halfFor(double dx, double width) => dx < width / 2 ? -1 : 1;

  /// Whether the current page reports itself zoomed past its fitted size.
  bool get _zoomedIn => widget.descriptor.value.zoomed?.value ?? false;

  void _onTap(Offset pos, double width) {
    // An open info panel swallows the tap to close, wherever it landed —
    // paging out from under a half-open panel would leave it stranded over
    // the next item's content.
    if (_panelExtent > 0) {
      _lastTapTime = null;
      _snapPanelTo(0);
      return;
    }

    final now = DateTime.now();
    final withinTime =
        _lastTapTime != null &&
        now.difference(_lastTapTime!) < kDoubleTapTimeout;
    final withinSlop =
        _lastTapPos != null && (pos - _lastTapPos!).distance < _doubleTapSlop;
    final isSecondTapOfDouble = withinTime && withinSlop;

    // Every tap acts immediately — no more "wait out kDoubleTapTimeout in
    // case a second tap follows" before paging/toggling chrome. A genuine
    // double-tap still gets detected and fires its own action (zoom/seek)
    // *in addition to* whatever the first tap already did.
    if (isSecondTapOfDouble) {
      _lastTapTime = null;
      _lastTapPos = null;
    } else {
      _lastTapTime = now;
      _lastTapPos = pos;
    }

    _handleSingleTap(_zoneFor(pos.dx, width));
    if (isSecondTapOfDouble) _handleDoubleTap(pos, width);
  }

  void _handleSingleTap(int zone) {
    // While zoomed into a photo, an edge tap means "I'm looking at this
    // corner", not "page to the next one" — paging out from under someone
    // inspecting a detail is never what they meant. Only the chrome toggle
    // stays live.
    final paging = !_zoomedIn;
    switch (zone) {
      case -1 when paging && widget.onPrevious != null:
        widget.onPrevious!();
      case 1 when paging && widget.onNext != null:
        widget.onNext!();
      default:
        setState(() => _chromeVisible = !_chromeVisible);
        _chromeVisibleNotifier.value = _chromeVisible;
    }
  }

  void _handleDoubleTap(Offset pos, double width) {
    final d = widget.descriptor.value;
    final zoom = d.onDoubleTapZoom;
    if (zoom != null) {
      zoom(pos);
      return;
    }
    switch (_halfFor(pos.dx, width)) {
      case -1 when d.onSeekBackward != null:
        d.onSeekBackward!();
        _showSeekHint(onLeft: true);
      case 1 when d.onSeekForward != null:
        d.onSeekForward!();
        _showSeekHint(onLeft: false);
    }
  }

  void _showSeekHint({required bool onLeft}) {
    _seekHintTimer?.cancel();
    setState(() {
      _seekHint = '5s';
      _seekHintOnLeft = onLeft;
    });
    _seekHintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekHint = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final descriptor = widget.descriptor.value;
    final panelOpenFraction = (_panelExtent / _maxPanelExtent).clamp(0.0, 1.0);
    final safeTop = MediaQuery.of(context).padding.top;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    // Fades out as the swipe-down-to-dismiss drag progresses, floored so it
    // never goes fully invisible before the release actually pops the route.
    final dismissFade = (1 - _dismissOffset / 500).clamp(0.35, 1.0);

    return Transform.translate(
      offset: Offset(0, _dismissOffset),
      child: Opacity(
        opacity: dismissFade,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: Listener(
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    child: _ViewerTapShieldScope(
                      claimed: _shieldedPointers,
                      child: ViewerFullscreen(
                        controller: _fullscreen,
                        child: ViewerChromeVisibility(
                          visible: _chromeVisibleNotifier,
                          child: widget.child,
                        ),
                      ),
                    ),
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
                              Builder(builder: descriptor.infoBuilder),
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
                    alignment: _seekHintOnLeft
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
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

            // Top scrim + back button, shown/hidden together with the bottom
            // bar and (for video) the seek bar/play button — all driven by
            // the same _chromeVisible flag/notifier so nothing ever
            // disagrees about whether the chrome is up.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_chromeVisible || _panelExtent > 0,
                child: AnimatedOpacity(
                  opacity: (_chromeVisible && _panelExtent == 0) ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: _BlurredScrim(
                    height: safeTop + 72,
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: safeTop + 4,
                        left: 4,
                        right: 4,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed:
                              widget.onBack ??
                              () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            if (descriptor.actions.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: !_chromeVisible || _panelExtent > 0,
                  child: AnimatedOpacity(
                    opacity: (_chromeVisible && _panelExtent == 0) ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: _BlurredScrim(
                      height: safeBottom + kViewerBottomBarHeight,
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: safeBottom + 8,
                          top: 24,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (final a in descriptor.actions)
                              _FloatingAction(action: a),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A darkened strip behind the top/bottom controls: a gradient that eases
/// out from [begin] to fully transparent at [end], so it reads as legible
/// chrome over any content (including a photo that's white edge to edge)
/// without a hard band.
///
/// This used to also blur the content behind it (`BackdropFilter` +
/// `ClipRect`) for a frosted-glass look. Removed: [PageView] with a
/// `BackdropFilter` in every page is a known, filed Flutter performance
/// problem (flutter/flutter#133910) — `allowImplicitScrolling` keeps both
/// the current and neighbouring pages alive during a swipe, so a
/// transition was recomputing this blur (x2 per page, x2 pages) on every
/// single frame of the animation. That, not image decode, was the actual
/// dominant cost behind the low-fps photo-to-photo transition — confirmed
/// against the upstream issue before changing this, not guessed. A plain
/// gradient reads almost identically in motion (where it matters most) and
/// costs nothing to composite.
class _BlurredScrim extends StatelessWidget {
  const _BlurredScrim({
    required this.height,
    required this.begin,
    required this.end,
    required this.child,
  });

  final double height;
  final Alignment begin;
  final Alignment end;
  final Widget child;

  // Alpha values sampled along an ease-out curve rather than a straight
  // line, so the fade reads as smooth/gradual instead of a visible edge —
  // this is the "muy directa la transición" complaint.
  static const _stops = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0];
  static const _alphas = [0.75, 0.66, 0.52, 0.34, 0.16, 0.0];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: begin,
          end: end,
          stops: _stops,
          colors: [
            for (final a in _alphas) Colors.black.withValues(alpha: a),
          ],
        ),
      ),
      child: child,
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
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
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
    final color = action.color ?? Colors.white;
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
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
