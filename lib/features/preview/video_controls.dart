import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show Player;
import 'package:media_kit_video/media_kit_video.dart';
import 'widgets/viewer_page_chrome.dart';

const double _seekBarSideMargin = 16;

/// Telegram blue, the seek bar's accent.
const Color _seekBarBlue = Color(0xFF2AABEE);

/// The bar's visible thickness (media_kit's default, kept: the hit area grows,
/// the line does not).
const double _seekBarLineHeight = 2.4;

/// Height of the bar's transparent hit container (media_kit's default is 36).
/// The extra 14 dp makes the bar easier to hit with a thumb.
const double kSeekBarHitHeight = 50;

/// How far the bar's centre line sits above the bottom of the hit container.
/// The bar's visible position must not change, so the extra hit area goes
/// mostly above it, and this much below it (the bottom margin is reduced by the
/// same amount, so the container never reaches into the bottom action row).
const double kSeekBarHitBelow = 13;

/// Vertical alignment (-1 top .. 1 bottom) that puts the bar's line
/// [kSeekBarHitBelow] above the bottom of the [kSeekBarHitHeight] container.
double get _seekBarAlignmentY {
  final top = kSeekBarHitHeight - kSeekBarHitBelow - _seekBarLineHeight / 2;
  return 2 * top / (kSeekBarHitHeight - _seekBarLineHeight) - 1;
}

/// Bottom margin of the seek bar for a given [bottomInset]: the old position
/// (container bottom [kViewerBottomBarHeight] + 12 above the bottom row, bar
/// line 1.2 dp above the container bottom) kept, with the container extended
/// [kSeekBarHitBelow] - 1.2 dp lower.
double seekBarBottomMargin(double bottomInset) =>
    bottomInset +
    kViewerBottomBarHeight +
    12 -
    (kSeekBarHitBelow - _seekBarLineHeight / 2);

/// Full-screen toggle for the video viewer: landscape + hidden system bars,
/// and back to portrait + edge-to-edge. The viewer is already full-bleed, so
/// "full screen" here only means rotating and hiding the status/navigation
/// bars.
///
/// The state is the viewer's, not the page's: every button reads and toggles
/// the one [ViewerFullscreenController] that [ViewerChromeHost] provides, so a
/// neighbouring page (the PageView keeps them alive) always agrees, and the
/// host restores portrait when the viewer is left. Without a host (nothing to
/// share with) the button keeps its own state and restores it on dispose.
class FullscreenToggleButton extends StatefulWidget {
  const FullscreenToggleButton({super.key});

  @override
  State<FullscreenToggleButton> createState() => _FullscreenToggleButtonState();
}

class _FullscreenToggleButtonState extends State<FullscreenToggleButton> {
  ViewerFullscreenController? _fallback;

  @override
  void dispose() {
    _fallback?.restoreIfOn();
    _fallback?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller =
        ViewerFullscreen.maybeOf(context) ??
        (_fallback ??= ViewerFullscreenController());
    return ValueListenableBuilder<bool>(
      valueListenable: controller,
      builder: (context, on, _) => Material(
        color: Colors.black38,
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: on ? 'Salir de pantalla completa' : 'Pantalla completa',
          icon: Icon(
            on ? Icons.fullscreen_exit : Icons.fullscreen,
            color: Colors.white,
          ),
          onPressed: controller.toggle,
        ),
      ),
    );
  }
}

/// Makes a plain tap on [MaterialSeekBar] jump to the tapped point.
///
/// media_kit_video 1.3.1's bar only reads the pointer position on *move*: a
/// tap (down + up, no move) seeks to the slider's previous value, i.e. it
/// stays where it was. This listens to the same raw pointer events from
/// outside (a [Listener] takes no part in the gesture arena, so the bar's own
/// drag handling is untouched) and, when the pointer went down and up without
/// moving past the touch slop, seeks to the tapped fraction. Outer listeners
/// run after the bar's own, so this seek is the one that sticks.
class TapToSeek extends StatefulWidget {
  const TapToSeek({
    super.key,
    required this.player,
    required this.horizontalMargin,
    required this.child,
  });

  final Player player;

  /// The bar's own left/right margin inside this widget (seekBarMargin).
  final double horizontalMargin;
  final Widget child;

  /// Fraction (0..1) of the track at local x [dx] for a widget [width] wide
  /// whose track is inset by [margin] on each side.
  static double fractionAt(double dx, double width, double margin) {
    final track = width - 2 * margin;
    if (track <= 0) return 0;
    return ((dx - margin) / track).clamp(0.0, 1.0);
  }

  @override
  State<TapToSeek> createState() => _TapToSeekState();
}

class _TapToSeekState extends State<TapToSeek> {
  Offset? _down;
  bool _moved = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerDown: (e) {
          _down = e.localPosition;
          _moved = false;
        },
        onPointerMove: (e) {
          final down = _down;
          if (down != null && (e.localPosition - down).distance > kTouchSlop) {
            _moved = true;
          }
        },
        onPointerUp: (e) {
          final down = _down;
          _down = null;
          if (down == null || _moved) return;
          final duration = widget.player.state.duration;
          if (duration <= Duration.zero) return;
          final f = TapToSeek.fractionAt(
            e.localPosition.dx,
            constraints.maxWidth,
            widget.horizontalMargin,
          );
          widget.player.seek(duration * f);
        },
        onPointerCancel: (_) => _down = null,
        child: widget.child,
      ),
    );
  }
}

/// Video controls for the full-screen viewer: just a seek bar and a center
/// play/pause button, built directly from media_kit's public sub-widgets
/// rather than [MaterialVideoControls].
///
/// [MaterialVideoControls] wraps everything in its own full-surface
/// `GestureDetector` that *always* registers horizontal-drag, vertical-drag,
/// and double-tap recognizers — theme flags like `seekGesture`/
/// `volumeGesture` only gate what the callback does once one of those wins
/// the gesture arena, not whether the recognizer is registered and
/// competing for the pointer in the first place. That competed with — and
/// sometimes won over — this viewer's own swipe-to-next-video (PageView),
/// swipe-down-to-dismiss, and double-tap-seek, no matter how the theme was
/// configured. Using just the bar and button, with no gesture surface
/// underneath them, sidesteps the conflict instead of trying to out-race it.
///
/// Visibility is driven by [ViewerChromeVisibility] — the same flag
/// [ViewerChromeHost] uses for its own top bar and action row — so the seek
/// bar, play/pause button, and the rest of the chrome always show and hide
/// together as one unit, tapped anywhere on the screen.
Widget Function(VideoState) videoSeekControls() {
  return (VideoState state) {
    final platform = Theme.of(state.context).platform;
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
      return AdaptiveVideoControls(state);
    }
    final media = MediaQuery.of(state.context);
    final theme = MaterialVideoControlsThemeData(
      // ViewerChromeHost draws its own bottom action row (Share/Upload/...)
      // in a blurred scrim kViewerBottomBarHeight tall, layered on top of
      // this seek bar in the same screen region — without clearing that
      // height, the bar renders (Video already gives this a
      // Positioned.fill, so it's not a sizing problem) but sits directly
      // underneath that scrim, completely hidden by it.
      seekBarMargin: EdgeInsets.only(
        left: _seekBarSideMargin,
        right: _seekBarSideMargin,
        bottom: seekBarBottomMargin(media.padding.bottom),
      ),
      seekBarHeight: _seekBarLineHeight,
      seekBarContainerHeight: kSeekBarHitHeight,
      seekBarAlignment: Alignment(0, _seekBarAlignmentY),
      seekBarPositionColor: _seekBarBlue,
      seekBarThumbColor: _seekBarBlue,
      seekBarBufferColor: Colors.white.withValues(alpha: 0.4),
      seekBarColor: Colors.white.withValues(alpha: 0.25),
    );
    final content = MaterialVideoControlsTheme(
      normal: theme,
      fullscreen: theme,
      child: Stack(
        children: [
          const Align(
            child: ViewerTapShield(
              child: MaterialPlayOrPauseButton(iconSize: 64),
            ),
          ),
          Positioned(
            right: 8,
            bottom: media.padding.bottom + kViewerBottomBarHeight + 52,
            child: const ViewerTapShield(child: FullscreenToggleButton()),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ViewerTapShield(
              child: TapToSeek(
                player: state.widget.controller.player,
                horizontalMargin: _seekBarSideMargin,
                child: const MaterialSeekBar(),
              ),
            ),
          ),
        ],
      ),
    );

    final visible = ViewerChromeVisibility.maybeOf(state.context);
    if (visible == null) return content;
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (context, isVisible, child) => IgnorePointer(
        ignoring: !isVisible,
        child: AnimatedOpacity(
          opacity: isVisible ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: child,
        ),
      ),
      child: content,
    );
  };
}
