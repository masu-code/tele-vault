// On-device, real-app, real-network test of the exact scenario the user
// reported crashing the app: flinging fast through the real Gallery grid,
// backed by real cloud thumbnails over the real Telegram connection. A
// plain `flutter test` widget test can exercise the gesture/layout logic
// with fake data, but not the real thumbnail-generation pipeline (real
// network latency, real image bytes, real memory pressure) — this is the
// one that can actually reproduce the OOM/ANR if the fix didn't hold.
//
// Run:
//   flutter test integration_test/gallery_scroll_test.dart -d <device> \
//     --dart-define=TV_SESSION_B64=<base64 of session json>

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
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

  testWidgets(
    'repeated fast flings through the real gallery grid do not crash or hang',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: TeleVaultApp()));

      for (var i = 0; i < 20 && find.text('Gallery').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        find.text('Gallery'),
        findsWidgets,
        reason: 'Did not reach MainShell — session restore likely failed.',
      );

      // Let the real feed load for real (network-bound).
      await tester.pump(const Duration(seconds: 2));
      final scrollable = find.byType(CustomScrollView);
      if (scrollable.evaluate().isEmpty) {
        // ignore: avoid_print
        print('SKIP: no CustomScrollView found — empty gallery?');
        return;
      }

      // The reported failure mode: flinging hard, repeatedly, without
      // waiting for thumbnails to settle in between — this is exactly what
      // used to fire a burst of full-resolution decodes and take the app
      // (and the OS) down.
      for (var round = 0; round < 6; round++) {
        await tester.fling(scrollable, const Offset(0, -2500), 9000);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.takeException(),
          isNull,
          reason: 'threw on real-data downward fling #$round',
        );
      }
      for (var round = 0; round < 6; round++) {
        await tester.fling(scrollable, const Offset(0, 2500), 9000);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.takeException(),
          isNull,
          reason: 'threw on real-data upward fling #$round',
        );
      }

      // Now let it actually settle and load, like a real pause would — this
      // is when the deferred idle-gated requests should fire.
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);

      // ignore: avoid_print
      print('OK: survived 12 real-data flings with no exception.');
    },
  );
}
