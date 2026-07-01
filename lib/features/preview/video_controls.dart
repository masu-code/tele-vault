import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// On mobile, lifts the seek bar and button bar above the Android gesture-nav
/// area — media_kit's Material controls default to sitting flush against the
/// bottom edge, which on gesture-nav devices overlaps the system bar and is
/// hard to tap/drag. Desktop keeps the stock adaptive controls untouched.
Widget videoControlsWithSafeInsets(VideoState state) {
  final platform = Theme.of(state.context).platform;
  if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
    return AdaptiveVideoControls(state);
  }
  final bottomInset = MediaQuery.of(state.context).padding.bottom;
  final theme = MaterialVideoControlsThemeData(
    seekBarMargin: EdgeInsets.only(bottom: bottomInset + 16),
    bottomButtonBarMargin: EdgeInsets.only(left: 16, right: 8, bottom: bottomInset + 16),
  );
  return MaterialVideoControlsTheme(
    normal: theme,
    fullscreen: theme,
    child: MaterialVideoControls(state),
  );
}
