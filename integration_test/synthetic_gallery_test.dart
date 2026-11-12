// Synthetic-library gallery benchmark (profile build, on device).
//
// Privacy / safety (plan section 4): NO real asset and NO real cloud item is
// read. The feed is overridden with N generated cloud-only FileItems whose ids
// start with `synth-` and whose Telegram message ids are negative (never
// valid). Their thumbnails are generated JPEGs written into the thumb dir, and
// the "full-size" files the viewer opens are generated JPEGs written into the
// download cache, so no code path needs the network. SharedPreferences is
// replaced by an empty in-memory store for this process, so the real backup
// registry is never read. At the end the test fails if the Telegram client got
// connected (a network guard), and (unless TV_KEEP_SYNTH) deletes every
// `synth-*` file it created. Output is numbers only; no screenshots.
//
// Script (fixed): 3 slow flings, 3 fast flings, settle, scrollbar drag to 50 %
// and to 100 % (each followed by a settle), jump to top, open item 10, swipe 5
// pages, back. Wrapped in binding.watchPerformance; TvStats counters and frame
// timings are written to build/perf/synthetic_gallery.json by the driver.
//
// Run: tool/measure_device.ps1 -Test synthetic_gallery   (see perf_baseline.md)
//
// Dart defines: TV_SYNTH_N (6000), TV_IMG_CACHE_ITEMS (600), TV_IMG_CACHE_MB
// (120), TV_KEEP_SYNTH (false).
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tele_vault/core/backup/backup_registry.dart';
import 'package:tele_vault/core/diag/tv_stats.dart';
import 'package:tele_vault/core/telegram/client.dart';
import 'package:tele_vault/features/gallery/models/gallery_entry.dart';
import 'package:tele_vault/features/gallery/providers/gallery_feed_provider.dart';
import 'package:tele_vault/features/gallery/screens/gallery_screen.dart';
import 'package:tele_vault/models/file_item.dart';
import 'package:tele_vault/models/file_part.dart';

const int _synthN = int.fromEnvironment('TV_SYNTH_N', defaultValue: 6000);
const int _imgCacheItems = int.fromEnvironment('TV_IMG_CACHE_ITEMS', defaultValue: 600);
const int _imgCacheMb = int.fromEnvironment('TV_IMG_CACHE_MB', defaultValue: 120);
const bool _keepSynth = bool.fromEnvironment('TV_KEEP_SYNTH');

const int _months = 40;
const int _fullFiles = 24; // items 0..23 get a cached "full-size" JPEG

String synthId(int i) => 'synth-${i.toString().padLeft(5, '0')}';

// --------------------------------------------------------------------------
// Generated files (run in isolates; only primitives cross the boundary)
// --------------------------------------------------------------------------

void _genThumbRange(String dir, int start, int end) {
  for (var i = start; i < end; i++) {
    final f = File(p.join(dir, '${synthId(i)}.jpg'));
    if (f.existsSync() && f.lengthSync() > 0) continue;
    final im = img.Image(width: 256, height: 256);
    img.fill(im,
        color: img.ColorRgb8(30 + (i * 53) % 170, 30 + (i * 97) % 170, 30 + (i * 29) % 170));
    img.drawString(im, '$i',
        font: img.arial48, x: 12, y: 100, color: img.ColorRgb8(255, 255, 255));
    f.writeAsBytesSync(img.encodeJpg(im, quality: 75));
  }
}

int _genFullFile(String dir, String name, int i) {
  final f = File(p.join(dir, name));
  if (f.existsSync() && f.lengthSync() > 0) return f.lengthSync();
  const w = 1600, h = 1200;
  final im = img.Image(width: w, height: h);
  var s = i * 2654435761 + 12345;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      final n = (s >> 16) & 31;
      im.setPixelRgb(x, y, (x * 255 ~/ w + n) & 255, (y * 255 ~/ h + n) & 255,
          ((x + y) * 255 ~/ (w + h) + n) & 255);
    }
  }
  img.drawString(im, '$i',
      font: img.arial48, x: 40, y: 40, color: img.ColorRgb8(255, 255, 255));
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(img.encodeJpg(im, quality: 85));
  return f.lengthSync();
}

Future<void> _generateThumbs(String dir, int n) async {
  const workers = 4;
  final per = (n + workers - 1) ~/ workers;
  await Future.wait([
    for (var w = 0; w < workers; w++)
      Isolate.run(() => _genThumbRange(dir, w * per, ((w + 1) * per).clamp(0, n))),
  ]);
}

/// Deletes only `synth-*` entries.
Future<void> _cleanSynth(String thumbDir, String cacheDir) async {
  final td = Directory(thumbDir);
  if (await td.exists()) {
    await for (final e in td.list(followLinks: false)) {
      if (e is File && p.basename(e.path).startsWith('synth-')) await e.delete();
    }
  }
  final cd = Directory(cacheDir);
  if (await cd.exists()) {
    await for (final e in cd.list(followLinks: false)) {
      if (e is Directory && p.basename(e.path).startsWith('synth-')) {
        await e.delete(recursive: true);
      }
    }
  }
}

// --------------------------------------------------------------------------
// Reusable script pieces (also used by real_timing_test.dart)
// --------------------------------------------------------------------------

double percentileOf(List<num> values, double p) {
  if (values.isEmpty) return 0;
  final s = values.map((v) => v.toDouble()).toList()..sort();
  return s[(p * s.length).ceil().clamp(1, s.length) - 1];
}

double _rssMb() => ProcessInfo.currentRss / (1 << 20);

/// Pumps real-time frames for [d]; calls [onSample] about every [sampleEvery].
Future<void> pumpFor(
  WidgetTester tester,
  Duration d, {
  Duration sampleEvery = const Duration(milliseconds: 250),
  void Function()? onSample,
}) async {
  final sw = Stopwatch()..start();
  var lastSample = 0;
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
    if (onSample != null && sw.elapsedMilliseconds - lastSample >= sampleEvery.inMilliseconds) {
      lastSample = sw.elapsedMilliseconds;
      onSample();
    }
  }
}

/// Counts on-screen gallery tiles (widgets keyed by a string ValueKey that is
/// one of [keys]) and how many of them show no decoded image yet.
class TileSampler {
  TileSampler(this.tester, this.keys);
  final WidgetTester tester;
  final Set<String> keys;

  int samples = 0;
  int tilesSeen = 0;
  int tilesWithoutImage = 0;
  int maxWithoutImageInSample = 0;
  int lastVisible = 0;
  int lastWithoutImage = 0;

  void sample() {
    final root = tester.binding.rootElement;
    if (root == null) return;
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    var visible = 0, blank = 0;

    bool hasImage(Element e) {
      var found = false;
      void v(Element c) {
        if (found) return;
        final w = c.widget;
        if (w is RawImage && w.image != null) {
          found = true;
          return;
        }
        c.visitChildren(v);
      }

      e.visitChildren(v);
      return found;
    }

    void walk(Element e) {
      final k = e.widget.key;
      if (k is ValueKey<String> && keys.contains(k.value)) {
        final ro = e.renderObject;
        if (ro is RenderBox && ro.attached && ro.hasSize) {
          final c = ro.localToGlobal(ro.size.center(Offset.zero));
          if (c.dx >= 0 && c.dy >= 0 && c.dx <= screen.width && c.dy <= screen.height) {
            visible++;
            if (!hasImage(e)) blank++;
          }
        }
        return; // do not descend into a tile
      }
      e.visitChildren(walk);
    }

    root.visitChildren(walk);
    samples++;
    tilesSeen += visible;
    tilesWithoutImage += blank;
    if (blank > maxWithoutImageInSample) maxWithoutImageInSample = blank;
    lastVisible = visible;
    lastWithoutImage = blank;
  }

  Map<String, dynamic> toJson() => {
        'samples': samples,
        'tilesSeen': tilesSeen,
        'tilesWithoutImage': tilesWithoutImage,
        'pctWithoutImage': tilesSeen == 0 ? 0 : (tilesWithoutImage * 10000 / tilesSeen).round() / 100,
        'maxWithoutImageInSample': maxWithoutImageInSample,
      };
}

ScrollPosition _gridPosition(WidgetTester tester) {
  final s = tester.state<ScrollableState>(
    find.descendant(of: find.byType(CustomScrollView).first, matching: find.byType(Scrollable)).first,
  );
  return s.position;
}

double _fraction(WidgetTester tester) {
  final pos = _gridPosition(tester);
  return pos.maxScrollExtent <= 0 ? 0 : pos.pixels / pos.maxScrollExtent;
}

/// Drags the FastScrollbar thumb until the list is at [target] (0..1).
Future<void> dragScrollbarTo(WidgetTester tester, double target, TileSampler s) async {
  final grid = find.byType(CustomScrollView).first;
  // The thumb only accepts touches after a scroll made it visible.
  await tester.drag(grid, const Offset(0, -30));
  await tester.pump(const Duration(milliseconds: 50));
  final thumb = find.byIcon(Icons.keyboard_arrow_up);
  if (thumb.evaluate().isEmpty) return;
  final g = await tester.startGesture(tester.getCenter(thumb.first));
  for (var i = 0; i < 600; i++) {
    await g.moveBy(const Offset(0, 20));
    await tester.pump(const Duration(milliseconds: 16));
    if (i % 15 == 0) s.sample();
    if (_fraction(tester) >= target - 0.002) break;
  }
  await g.up();
}

bool _hasFullRes(WidgetTester tester) {
  var found = false;
  void v(Element e) {
    if (found) return;
    final w = e.widget;
    if (w is RawImage) {
      final im = w.image;
      if (im != null && im.width >= 600) {
        found = true;
        return;
      }
    }
    e.visitChildren(v);
  }

  tester.binding.rootElement?.visitChildren(v);
  return found;
}

/// Taps [tile], returns ms until a decoded image >= 600 px wide is on the
/// tree (the viewer's full-resolution frame), or -1 after [timeout].
Future<int> tapToFullRes(WidgetTester tester, Finder tile,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final sw = Stopwatch()..start();
  await tester.tap(tile, warnIfMissed: false);
  while (sw.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 16));
    if (_hasFullRes(tester)) return sw.elapsedMilliseconds;
  }
  return -1;
}

Future<void> popRoute(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).pop();
  await pumpFor(tester, const Duration(milliseconds: 1200));
}

/// The fixed gallery script. Returns per-phase numbers (no content).
/// [viewer] false skips "tap item, swipe 5 pages, back".
Future<Map<String, dynamic>> runGalleryScript(
  WidgetTester tester,
  List<GalleryEntry> entries, {
  bool viewer = true,
  int tapIndex = 10,
}) async {
  final sampler = TileSampler(tester, {for (final e in entries) e.key});
  final grid = find.byType(CustomScrollView).first;
  final phases = <Map<String, dynamic>>[];
  final total = Stopwatch()..start();

  Future<void> phase(String name, Future<void> Function() body) async {
    final sw = Stopwatch()..start();
    final before = sampler.toJson();
    await body();
    phases.add({
      'name': name,
      'ms': sw.elapsedMilliseconds,
      'rssMb': (_rssMb() * 10).round() / 10,
      'tilesSeenDelta': (sampler.tilesSeen - (before['tilesSeen'] as int)),
      'tilesWithoutImageDelta':
          (sampler.tilesWithoutImage - (before['tilesWithoutImage'] as int)),
    });
  }

  Future<void> settleAndCheckRest(String label, Map<String, dynamic> out) async {
    await pumpFor(tester, const Duration(milliseconds: 2000), onSample: sampler.sample);
    sampler.sample();
    out[label] = {'visible': sampler.lastVisible, 'withoutImage': sampler.lastWithoutImage};
  }

  final rest = <String, dynamic>{};
  final viewerMs = <String, dynamic>{};

  await phase('slowFlings', () async {
    for (var i = 0; i < 3; i++) {
      await tester.fling(grid, const Offset(0, -300), 800);
      await pumpFor(tester, const Duration(milliseconds: 2500), onSample: sampler.sample);
    }
  });
  await phase('fastFlings', () async {
    for (var i = 0; i < 3; i++) {
      await tester.fling(grid, const Offset(0, -2500), 9000);
      await pumpFor(tester, const Duration(milliseconds: 3000), onSample: sampler.sample);
    }
  });
  await phase('settleAfterFlings', () => settleAndCheckRest('afterFlings', rest));
  await phase('scrollbarDrag50', () async {
    await dragScrollbarTo(tester, 0.5, sampler);
    await settleAndCheckRest('afterDrag50', rest);
  });
  await phase('scrollbarDrag100', () async {
    await dragScrollbarTo(tester, 1.0, sampler);
    await settleAndCheckRest('afterDrag100', rest);
  });
  await phase('backToTop', () async {
    _gridPosition(tester).jumpTo(0);
    await settleAndCheckRest('atTop', rest);
  });

  if (viewer && entries.length > tapIndex) {
    final tile = find.byKey(ValueKey<String>(entries[tapIndex].key));
    await phase('openViewer', () async {
      viewerMs['tapToFullResMs'] = await tapToFullRes(tester, tile);
    });
    await phase('swipe5Pages', () async {
      for (var i = 0; i < 5; i++) {
        final pv = find.byType(PageView);
        if (pv.evaluate().isEmpty) break;
        await tester.fling(pv.first, const Offset(-500, 0), 1200);
        await pumpFor(tester, const Duration(milliseconds: 1200));
      }
    });
    await phase('backFromViewer', () async {
      await popRoute(tester);
    });
  }

  return {
    'scriptMs': total.elapsedMilliseconds,
    'phases': phases,
    'tiles': sampler.toJson(),
    'restChecks': rest,
    'viewer': viewerMs,
    'rssMbEnd': (_rssMb() * 10).round() / 10,
  };
}

// --------------------------------------------------------------------------
// The test
// --------------------------------------------------------------------------

// Top-level so the isolate closure captures only primitives (a closure inside
// the test body captures the WidgetTester context, which is unsendable).
Future<int> _genFullFileIsolated(String dir, int i) =>
    Isolate.run(() => _genFullFile(dir, '${synthId(i)}.jpg', i));

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('synthetic gallery: scripted scroll + viewer on a generated library',
      (tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    MediaKit.ensureInitialized();
    PaintingBinding.instance.imageCache
      ..maximumSize = _imgCacheItems
      ..maximumSizeBytes = _imgCacheMb << 20;

    // Never read or touch the owner's real registry: empty in-memory prefs AND
    // a scratch database directory (opening the real tv_registry.db would run
    // the prefs migration against these empty prefs and mark it done).
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final tmp = await getTemporaryDirectory();
    final registryDir = Directory(p.join(tmp.path, 'tv_synth_registry'));
    if (registryDir.existsSync()) registryDir.deleteSync(recursive: true);
    registryDir.createSync(recursive: true);
    BackupRegistry.instance.debugUseDirectory(registryDir.path);
    await BackupRegistry.instance.init();

    final support = await getApplicationSupportDirectory();
    final thumbDir = p.join(support.path, 'televault_thumbs');
    await Directory(thumbDir).create(recursive: true);
    final cacheDir = p.join(tmp.path, 'televault_cache');

    // ---- generate files (untimed) ----
    final genWatch = Stopwatch()..start();
    await _generateThumbs(thumbDir, _synthN);
    final fullSizes = <int, int>{};
    for (var i = 0; i < _fullFiles && i < _synthN; i++) {
      final dir = p.join(cacheDir, synthId(i));
      fullSizes[i] = await _genFullFileIsolated(dir, i);
    }
    // ignore: avoid_print
    print('TVDIAG: synthetic files ready n=$_synthN in ${genWatch.elapsedMilliseconds} ms');

    // ---- synthetic feed: N cloud-only items over 40 months, newest first ----
    final perMonth = (_synthN + _months - 1) ~/ _months;
    final entries = <GalleryEntry>[];
    for (var i = 0; i < _synthN; i++) {
      final m = i ~/ perMonth;
      final j = i % perMonth;
      final size = fullSizes[i] ?? 150000;
      entries.add(GalleryEntry(
        fileItem: FileItem(
          id: synthId(i),
          name: '${synthId(i)}.jpg',
          folderId: null,
          totalSize: size,
          mimeType: 'image/jpeg',
          createdAt: DateTime(2026, 11 - m, 28, 23, 59).subtract(Duration(minutes: j * 5)),
          parts: [FilePart(messageId: -(i + 1), part: 0, size: size)],
        ),
      ));
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [galleryFeedProvider.overrideWith((ref) async => entries)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF2AABEE),
              surface: Color(0xFF1C1C1E),
            ),
          ),
          home: const GalleryScreen(),
        ),
      ),
    );
    for (var i = 0; i < 40 && find.byType(CustomScrollView).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(CustomScrollView), findsWidgets, reason: 'synthetic feed did not render');
    await pumpFor(tester, const Duration(seconds: 2)); // warm-up, not measured

    TvStats.reset();
    TvStats.startMonitoring();
    late Map<String, dynamic> script;
    await binding.watchPerformance(() async {
      // ignore: avoid_print
      print('TVDIAG: SCRIPT_START');
      script = await runGalleryScript(tester, entries);
      // ignore: avoid_print
      print('TVDIAG: SCRIPT_END');
    }, reportKey: 'frames');
    TvStats.stopMonitoring();
    final stats = TvStats.snapshot();

    expect(tester.takeException(), isNull);
    // Network guard: nothing in this test may have connected the real client.
    final networkTouched = TelegramService.instance.isConnected;

    binding.reportData = <String, dynamic>{
      ...?binding.reportData,
      'testName': 'synthetic_gallery',
      'items': _synthN,
      'imageCache': {'items': _imgCacheItems, 'mb': _imgCacheMb},
      'tvStats': stats,
      'script': script,
      'networkTouched': networkTouched,
    };
    // ignore: avoid_print
    print('TVDIAG: RESULT blankFrames=${stats['tileBlankFrames']} hooks=${stats['tileHooksActive']} '
        'jankyPct=${stats['jankyPct']} longestUiTaskMs=${stats['longestUiTaskMs']} '
        'rssMb=${stats['rssMb']} tapToFullResMs=${(script['viewer'] as Map)['tapToFullResMs']} '
        'restChecks=${script['restChecks']}');

    // Hold the final state so the host can take gfxinfo / meminfo.
    // ignore: avoid_print
    print('TVDIAG: HOLD');
    await pumpFor(tester, const Duration(seconds: 10));

    if (!_keepSynth) await _cleanSynth(thumbDir, cacheDir);
    try {
      registryDir.deleteSync(recursive: true);
    } catch (_) {}
    expect(networkTouched, isFalse, reason: 'synthetic test connected to Telegram');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
