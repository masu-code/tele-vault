// On-device, real-app, real-network test of the video viewer fixes:
// - the seek bar/play-pause button actually render (not hidden under the
//   action-row scrim, and not empty-Stack-collapsed)
// - swipe-down-to-dismiss actually closes the viewer, driven through the
//   real media_kit Video widget this time, not a placeholder
//
// Runs as instrumentation (tester.drag/tap), not synthetic adb input events
// — MIUI blocks the latter but not the former, per this repo's established
// device-testing approach (see tool/run_device_tests.ps1).
//
// Run:
//   flutter test integration_test/video_viewer_test.dart -d <device> \
//     --dart-define=TV_SESSION_B64=<base64 of session json>

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tele_vault/app/app.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const _sessionB64 = String.fromEnvironment('TV_SESSION_B64');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await WakelockPlus.enable();
    MediaKit.ensureInitialized();
    PaintingBinding.instance.imageCache
      ..maximumSize = 200
      ..maximumSizeBytes = 100 << 20;

    expect(
      _sessionB64.isNotEmpty,
      isTrue,
      reason: 'Pass --dart-define=TV_SESSION_B64=<base64 of session json>',
    );
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/tele_vault_session.json');
    await f.writeAsString(utf8.decode(base64.decode(_sessionB64)));
  });

  tearDownAll(() async {
    await WakelockPlus.disable();
  });

  testWidgets('open a video, seek bar renders, swipe down dismisses it', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: TeleVaultApp()));

    // Cold start: waiting for the saved session to restore and MainShell to
    // take over from the splash/login screen.
    for (var i = 0; i < 20 && find.text('Gallery').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(
      find.text('Gallery'),
      findsWidgets,
      reason: 'Did not reach MainShell — session restore likely failed.',
    );

    // Gallery is the default tab, but give its feed a moment to load and
    // render tiles.
    for (
      var i = 0;
      i < 20 && find.byIcon(Icons.play_circle_fill).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final videoTileFinder = find.byIcon(Icons.play_circle_fill);
    if (videoTileFinder.evaluate().isEmpty) {
      // ignore: avoid_print
      print('SKIP: no video in this account\'s gallery to test against.');
      return;
    }

    await tester.tap(videoTileFinder.first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Let the video actually open/buffer.
    for (
      var i = 0;
      i < 20 && find.byType(MaterialSeekBar).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(
      find.byType(MaterialSeekBar),
      findsOneWidget,
      reason:
          'Seek bar never appeared — either still hidden behind the action '
          'row scrim, or the video never loaded.',
    );
    expect(
      find.byType(MaterialPlayOrPauseButton),
      findsOneWidget,
      reason: 'Play/pause button missing from the video controls.',
    );

    // The actual reported bug: this used to be silently eaten by
    // InteractiveViewer's gesture recognizer.
    await tester.drag(find.byType(Scaffold).first, const Offset(0, 600));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(
      find.byType(MaterialSeekBar),
      findsNothing,
      reason: 'Swipe-down should have dismissed the video viewer.',
    );
    expect(
      find.text('Gallery'),
      findsWidgets,
      reason: 'Swipe-down-to-dismiss should land back on Gallery.',
    );
  });
}
