// OPTIONAL, owner permission needed EVERY time: runs the gallery script on the
// REAL library of the app already installed/logged in on the device.
//
// It uses the real session and real feed (so it reads real cloud items, and
// the viewer step opens real photos, which can download them). It records and
// prints NUMBERS ONLY: TvStats counters, frame timings, tile-without-image
// counts and tap-to-full-resolution timings. No names, paths, captions or
// thumbnails are read into any output; no screenshots.
//
// Script: same as synthetic_gallery_test (flings, scrollbar drags, back to
// top), then tap-to-full-res on up to 4 on-device and 4 cloud-only photos taken
// from the first 120 feed entries (each opened and closed on its own).
//
// Run: tool/measure_device.ps1 -Test real_timing -AllowReal
// Dart defines: TV_SESSION_B64 (optional; otherwise the session already in the
// app's data is used), TV_REAL_WAIT_S (idle seconds before measuring, default
// 20, lets the device prefill / thumbs settle), TV_IMG_CACHE_ITEMS/TV_IMG_CACHE_MB.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tele_vault/app/app.dart';
import 'package:tele_vault/core/diag/tv_stats.dart';
import 'package:tele_vault/core/download/download_worker.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/providers/gallery_feed_provider.dart';

import 'synthetic_gallery_test.dart'
    show percentileOf, pumpFor, runGalleryScript, tapToFullRes, popRoute;

const _sessionB64 = String.fromEnvironment('TV_SESSION_B64');
const int _waitS = int.fromEnvironment('TV_REAL_WAIT_S', defaultValue: 20);
const int _imgCacheItems = int.fromEnvironment('TV_IMG_CACHE_ITEMS', defaultValue: 600);
const int _imgCacheMb = int.fromEnvironment('TV_IMG_CACHE_MB', defaultValue: 120);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real library: scripted scroll + tap-to-full-res (numbers only)',
      (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    MediaKit.ensureInitialized();
    PaintingBinding.instance.imageCache
      ..maximumSize = _imgCacheItems
      ..maximumSizeBytes = _imgCacheMb << 20;
    if (Platform.isAndroid) DownloadWorker.enabled = true; // as main() does

    if (_sessionB64.isNotEmpty) {
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/tele_vault_session.json')
          .writeAsString(utf8.decode(base64.decode(_sessionB64)));
    }

    await tester.pumpWidget(const ProviderScope(child: TeleVaultApp()));
    for (var i = 0; i < 120 && find.text('Gallery').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('Gallery'), findsWidgets,
        reason: 'Did not reach MainShell (no saved session?).');

    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp).first));
    List<GalleryEntry> entries = const [];
    for (var i = 0; i < 480 && entries.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      entries = container.read(galleryFeedProvider).valueOrNull ?? const [];
    }
    expect(entries, isNotEmpty, reason: 'feed never loaded');
    // ignore: avoid_print
    print('TVDIAG: real feed entries=${entries.length}');

    // Let device prefill / thumbs settle before measuring.
    await pumpFor(tester, Duration(seconds: _waitS));
    entries = container.read(galleryFeedProvider).valueOrNull ?? entries;

    TvStats.reset();
    TvStats.startMonitoring();
    late Map<String, dynamic> script;
    await binding.watchPerformance(() async {
      // ignore: avoid_print
      print('TVDIAG: SCRIPT_START');
      script = await runGalleryScript(tester, entries, viewer: false);
      // ignore: avoid_print
      print('TVDIAG: SCRIPT_END');
    }, reportKey: 'frames');
    TvStats.stopMonitoring();
    final stats = TvStats.snapshot();

    // ---- tap-to-full-res, one fresh viewer per photo ----
    final head = entries.take(120).toList();
    final device = <int>[
      for (var i = 0; i < head.length; i++)
        if (!head[i].isVideo && head[i].isOnDevice) i
    ].take(4).toList();
    final cloud = <int>[
      for (var i = 0; i < head.length; i++)
        if (!head[i].isVideo && !head[i].isOnDevice) i
    ].take(4).toList();

    Future<List<int>> measure(List<int> idx) async {
      final out = <int>[];
      final scrollable = find.descendant(
          of: find.byType(CustomScrollView).first, matching: find.byType(Scrollable)).first;
      for (final i in idx) {
        tester.state<ScrollableState>(scrollable).position.jumpTo(0);
        await pumpFor(tester, const Duration(seconds: 1));
        final tile = find.byKey(ValueKey<String>(head[i].key));
        await tester.scrollUntilVisible(tile, 300, scrollable: scrollable, maxScrolls: 80);
        await tester.pump(const Duration(milliseconds: 300));
        out.add(await tapToFullRes(tester, tile));
        await popRoute(tester);
      }
      return out;
    }

    final deviceMs = await measure(device);
    final cloudMs = await measure(cloud);
    List<int> valid(List<int> l) => l.where((v) => v >= 0).toList();

    binding.reportData = <String, dynamic>{
      ...?binding.reportData,
      'testName': 'real_timing',
      'tvStats': stats,
      'script': script,
      'tapToFullResMs': {
        'device': deviceMs,
        'cloud': cloudMs,
        'deviceP90': percentileOf(valid(deviceMs), 0.9),
        'cloudP90': percentileOf(valid(cloudMs), 0.9),
        'timeouts': deviceMs.where((v) => v < 0).length + cloudMs.where((v) => v < 0).length,
      },
    };
    // ignore: avoid_print
    print('TVDIAG: RESULT blankFrames=${stats['tileBlankFrames']} hooks=${stats['tileHooksActive']} '
        'jankyPct=${stats['jankyPct']} longestUiTaskMs=${stats['longestUiTaskMs']} '
        'rssMb=${stats['rssMb']} deviceMs=$deviceMs cloudMs=$cloudMs '
        'restChecks=${script['restChecks']}');
    // ignore: avoid_print
    print('TVDIAG: HOLD');
    await pumpFor(tester, const Duration(seconds: 10));
  }, timeout: const Timeout(Duration(minutes: 30)));
}
