import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tele_vault/features/preview/widgets/media_pages.dart';
import 'package:tele_vault/features/preview/widgets/photo_zoom_controller.dart';
import 'package:tele_vault/features/preview/widgets/viewer_page_chrome.dart';

// Pins the photo viewer's gestures end to end, through Flutter's real gesture
// arena (the same path a finger takes):
//   - pinch-to-zoom catches whatever the angle of the fingers, and never
//     pages or dismisses (the "a veces no agarra" complaint),
//   - the thumbnail can be zoomed before the full-resolution file arrives,
//     and the zoom is kept when it does,
//   - at scale 1 a horizontal swipe still pages and a vertical one dismisses,
//   - double tap zooms in/out around the tapped point, edge taps don't page
//     while zoomed, a zoomed drag pans, and the PageView freezes while zoomed.
//
// The harness is a miniature viewer screen built the way the real ones are
// (MediaViewerScreen / MixedMediaViewerScreen / DeviceAssetViewerScreen):
// ViewerZoomLock -> ViewerChromeHost -> PageView, each page a
// PhotoZoomController + the real `zoomablePhoto` from media_pages.dart.

const _pageCount = 3;

class _Viewer extends StatefulWidget {
  const _Viewer({
    required this.firstFile,
    required this.lock,
    this.showRing = false,
    this.onBack,
    this.onPrevious,
    this.onNext,
  });

  /// Page 0's full-resolution file; null = still loading (thumbnail only).
  final ValueNotifier<File?> firstFile;
  final ViewerZoomLock lock;

  /// Page 0 shows the loading ring while [firstFile] is null. Off by default:
  /// an indeterminate ring never lets pumpAndSettle settle.
  final bool showRing;
  final VoidCallback? onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  final PageController pages = PageController();
  final ValueNotifier<ViewerChromeDescriptor> _descriptor = ValueNotifier(
    const ViewerChromeDescriptor(),
  );
  int current = 0;

  @override
  void dispose() {
    pages.dispose();
    _descriptor.dispose();
    super.dispose();
  }

  void _report(int index, ViewerChromeDescriptor d) {
    if (index != current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _descriptor.value = d;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.lock,
      builder: (context, _, _) => ViewerChromeHost(
        descriptor: _descriptor,
        onBack: widget.onBack,
        onPrevious: widget.onPrevious,
        onNext: widget.onNext,
        onDismissDragChanged: widget.lock.reportDragging,
        child: PageView.builder(
          physics: widget.lock.physics,
          controller: pages,
          itemCount: _pageCount,
          onPageChanged: (i) => setState(() => current = i),
          itemBuilder: (context, i) => _PhotoPage(
            key: ValueKey('page$i'),
            index: i,
            file: i == 0 ? widget.firstFile : null,
            lock: widget.lock,
            showRing: widget.showRing,
            onDescriptor: _report,
          ),
        ),
      ),
    );
  }
}

class _PhotoPage extends StatefulWidget {
  const _PhotoPage({
    super.key,
    required this.index,
    required this.file,
    required this.lock,
    required this.showRing,
    required this.onDescriptor,
  });

  final int index;
  final bool showRing;
  final ValueNotifier<File?>? file;
  final ViewerZoomLock lock;
  final void Function(int, ViewerChromeDescriptor) onDescriptor;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage>
    with SingleTickerProviderStateMixin {
  late final PhotoZoomController zoom = PhotoZoomController(this);

  void _reportZoom() => widget.lock.report(zoom.zoomed.value);
  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    zoom.zoomed.addListener(_reportZoom);
    zoom.highRes.addListener(_rebuild);
    widget.file?.addListener(_rebuild);
  }

  @override
  void dispose() {
    zoom.zoomed.removeListener(_reportZoom);
    zoom.highRes.removeListener(_rebuild);
    widget.file?.removeListener(_rebuild);
    widget.lock.report(false);
    zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    widget.onDescriptor(
      widget.index,
      ViewerChromeDescriptor(
        infoBuilder: (context) => const Text('info panel content'),
        onDoubleTapZoom: zoom.toggleZoom,
        zoomed: zoom.zoomed,
      ),
    );
    final file = widget.file?.value;
    return zoomablePhoto(
      zoom: zoom,
      file: file,
      highRes: zoom.highRes.value,
      placeholder: const SizedBox.expand(
        child: ColoredBox(key: ValueKey('thumb'), color: Colors.blue),
      ),
      loading: widget.showRing && widget.index == 0 && file == null,
    );
  }
}

class _Harness {
  _Harness(this.tester);
  final WidgetTester tester;
  final ValueNotifier<File?> firstFile = ValueNotifier(null);
  final ViewerZoomLock lock = ViewerZoomLock();
  int back = 0;
  int previous = 0;
  int next = 0;

  Future<void> pump({File? file, bool showRing = false}) async {
    firstFile.value = file;
    addTearDown(firstFile.dispose);
    addTearDown(lock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _Viewer(
            firstFile: firstFile,
            lock: lock,
            showRing: showRing,
            onBack: () => back++,
            onPrevious: () => previous++,
            onNext: () => next++,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  PhotoZoomController zoomOf(int page) =>
      tester.state<_PhotoPageState>(find.byKey(ValueKey('page$page'))).zoom;

  int get currentPage =>
      tester.state<_ViewerState>(find.byType(_Viewer)).current;

  double get pageOffset =>
      tester.state<_ViewerState>(find.byType(_Viewer)).pages.page!;
}

/// tester.tapAt twice inside kDoubleTapTimeout, which is what
/// ViewerChromeHost's hand-rolled single/double-tap disambiguation reads.
Future<void> _doubleTapAt(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(position);
  await tester.pumpAndSettle();
}

/// Two fingers placed [degrees] off horizontal around [centre], spread apart
/// in small steps, interleaved the way real touch events arrive. With
/// [anchored] the first finger stays put and only the second one moves (a
/// thumb held still while the index finger spreads): its movement then counts
/// fully toward the PageView's horizontal drag slop but only half toward the
/// scale recognizer's span, which is the race the old InteractiveViewer lost
/// at shallow angles.
Future<void> _pinchOut(
  WidgetTester tester, {
  required double degrees,
  Offset centre = const Offset(400, 300),
  double startRadius = 40,
  double spread = 80,
  int steps = 8,
  bool anchored = false,
  bool settle = true,
}) async {
  final rad = degrees * math.pi / 180;
  final dir = Offset(math.cos(rad), math.sin(rad));
  final a = await tester.startGesture(centre - dir * startRadius, pointer: 11);
  await tester.pump(const Duration(milliseconds: 10));
  final b = await tester.startGesture(centre + dir * startRadius, pointer: 12);
  await tester.pump(const Duration(milliseconds: 10));
  final step = dir * (spread / steps);
  for (var i = 0; i < steps; i++) {
    if (anchored) {
      await b.moveBy(step * 2);
    } else {
      await a.moveBy(-step);
      await b.moveBy(step);
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  await a.up();
  await b.up();
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
}

/// A small real PNG on disk, so the full-resolution path decodes for real.
Future<File> _writePng(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp('tv_zoom_test');
    // Best effort: on Windows the decoder can still hold the file open.
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException catch (_) {}
    });
    final image = img.Image(width: 40, height: 30);
    img.fill(image, color: img.ColorRgb8(200, 50, 50));
    final file = File('${dir.path}/photo.png');
    await file.writeAsBytes(img.encodePng(image));
    return file;
  }))!;
}

void main() {
  group('pinch', () {
    for (final anchored in [false, true]) {
      for (final degrees in [0.0, 30.0, 80.0]) {
        testWidgets('two fingers at $degrees° '
            '${anchored ? '(one finger still) ' : ''}zoom the photo and '
            'neither page nor dismiss', (tester) async {
          final h = _Harness(tester);
          await h.pump();
          await _pinchOut(tester, degrees: degrees, anchored: anchored);

          final zoom = h.zoomOf(0);
          expect(zoom.scale, greaterThan(1.5), reason: 'the pinch must catch');
          expect(zoom.zoomed.value, isTrue);
          expect(h.currentPage, 0);
          expect(h.pageOffset, 0, reason: 'the PageView must not move');
          expect(h.back, 0, reason: 'a pinch is never a dismiss');
          expect(h.previous + h.next, 0);
        });
      }
    }

    testWidgets('a second finger landing mid swipe-down turns it into a pinch '
        'and the viewer snaps back', (tester) async {
      final h = _Harness(tester);
      await h.pump();
      final a = await tester.startGesture(const Offset(400, 250), pointer: 21);
      for (var i = 0; i < 4; i++) {
        await a.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final b = await tester.startGesture(const Offset(400, 380), pointer: 22);
      for (var i = 0; i < 8; i++) {
        await a.moveBy(const Offset(0, -10));
        await b.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();

      expect(h.back, 0);
      expect(h.zoomOf(0).scale, greaterThan(1.2));
      final translate = tester.widget<Transform>(
        find
            .descendant(
              of: find.byType(ViewerChromeHost),
              matching: find.byType(Transform),
            )
            .first,
      );
      expect(translate.transform.getTranslation().y, 0);
    });
  });

  group('progressive load', () {
    testWidgets('the thumbnail zooms before the full photo arrives, and the '
        'zoom is kept when it does', (tester) async {
      final h = _Harness(tester);
      await h.pump(showRing: true);
      expect(find.byKey(const ValueKey('thumb')), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Image), findsNothing, reason: 'still loading');

      // Centred on the ring: it must not swallow the pinch.
      await _pinchOut(
        tester,
        degrees: 45,
        centre: const Offset(400, 555),
        settle: false,
      );
      final zoom = h.zoomOf(0);
      final scale = zoom.scale;
      final position = zoom.view.position;
      expect(scale, greaterThan(1.5));

      // Zoomed past 1.5x: the page asks for the 2x decode.
      expect(zoom.highRes.value, isTrue);

      // The download finishes: decode the real file (file IO and decoding
      // need real async in a widget test) at the exact size the page asks
      // for, then hand the page its file.
      final file = await _writePng(tester);
      await tester.runAsync(() async {
        final element = tester.element(find.byType(_Viewer));
        await precacheImage(
          ResizeImage(
            FileImage(file),
            width: photoDecodeWidth(element, highRes: true),
          ),
          element,
        );
      });
      h.firstFile.value = file;
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect(raw.image, isNotNull, reason: 'full-resolution frame on screen');
      expect(raw.image!.width, 40);
      expect(zoom.scale, scale, reason: 'zoom kept across the swap');
      expect(zoom.view.position, position, reason: 'pan kept across the swap');
      expect(h.lock.value, isTrue, reason: 'still zoomed: paging frozen');
    });
  });

  group('at scale 1', () {
    testWidgets('a horizontal swipe pages', (tester) async {
      final h = _Harness(tester);
      await h.pump();
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1500);
      await tester.pumpAndSettle();
      expect(h.currentPage, 1);
      expect(h.zoomOf(1).scale, 1);
      expect(h.back, 0);
    });

    testWidgets('a vertical swipe down dismisses', (tester) async {
      final h = _Harness(tester);
      await h.pump();
      final g = await tester.startGesture(const Offset(400, 150));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, 30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(h.back, 1);
      expect(h.currentPage, 0);
    });

    testWidgets('a single tap in the middle toggles the chrome, an edge tap '
        'pages', (tester) async {
      final h = _Harness(tester);
      await h.pump();
      await tester.tapAt(const Offset(780, 300));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(h.next, 1);
      expect(h.zoomOf(0).zoomed.value, isFalse);
    });
  });

  group('double tap', () {
    testWidgets('zooms in, and a second double tap zooms back out', (
      tester,
    ) async {
      final h = _Harness(tester);
      await h.pump();
      final zoom = h.zoomOf(0);
      expect(zoom.zoomed.value, isFalse);

      await _doubleTapAt(tester, const Offset(400, 300));
      expect(zoom.zoomed.value, isTrue);
      expect(zoom.scale, closeTo(2.5, 0.01));

      await _doubleTapAt(tester, const Offset(400, 300));
      expect(zoom.zoomed.value, isFalse);
      expect(zoom.scale, closeTo(1, 0.001));
      expect(zoom.view.position, Offset.zero);
    });

    testWidgets('anchors on the tapped point, not the centre', (tester) async {
      final h = _Harness(tester);
      await h.pump();
      await _doubleTapAt(tester, const Offset(100, 150));
      // The top-left point stays under the finger only if the photo is
      // shifted right/down; a centre-only zoom would leave it at zero.
      final position = h.zoomOf(0).view.position;
      expect(position.dx, greaterThan(0));
      expect(position.dy, greaterThan(0));
    });
  });

  group('while zoomed', () {
    testWidgets('an edge tap does NOT page', (tester) async {
      final h = _Harness(tester);
      await h.pump();

      // Not zoomed: the narrow edge zones still page as before.
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(h.previous, 1);

      await _doubleTapAt(tester, const Offset(400, 300));
      expect(h.zoomOf(0).zoomed.value, isTrue);

      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      await tester.tapAt(const Offset(780, 300));
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(h.previous, 1, reason: 'edge tap must not page while zoomed');
      expect(h.next, 0, reason: 'edge tap must not page while zoomed');
    });

    testWidgets('the screen-level zoom lock freezes the PageView', (
      tester,
    ) async {
      final h = _Harness(tester);
      await h.pump();
      expect(h.lock.physics, isNull);

      await _doubleTapAt(tester, const Offset(400, 300));
      expect(h.lock.value, isTrue);
      expect(h.lock.physics, isA<NeverScrollableScrollPhysics>());

      await _doubleTapAt(tester, const Offset(400, 300));
      expect(h.lock.value, isFalse);
      expect(h.lock.physics, isNull);
    });

    testWidgets('a horizontal drag pans the photo instead of paging', (
      tester,
    ) async {
      final h = _Harness(tester);
      await h.pump();
      await _doubleTapAt(tester, const Offset(400, 300));
      final zoom = h.zoomOf(0);
      final before = zoom.view.position;

      await tester.dragFrom(const Offset(400, 300), const Offset(-150, 0));
      await tester.pumpAndSettle();

      expect(zoom.view.position.dx, lessThan(before.dx - 50));
      expect(h.currentPage, 0);
      expect(h.pageOffset, 0);
    });

    testWidgets('a vertical drag pans instead of opening info or dismissing', (
      tester,
    ) async {
      final h = _Harness(tester);
      await h.pump();
      await _doubleTapAt(tester, const Offset(400, 300));
      final zoom = h.zoomOf(0);
      final before = zoom.view.position;

      await tester.dragFrom(const Offset(400, 300), const Offset(0, 80));
      await tester.pumpAndSettle();

      expect(zoom.view.position.dy, isNot(closeTo(before.dy, 1)));
      expect(find.text('info panel content'), findsNothing);
      expect(h.back, 0);
    });

    testWidgets('tearing a zoomed page down releases the lock', (tester) async {
      final h = _Harness(tester);
      await h.pump();
      await _doubleTapAt(tester, const Offset(400, 300));
      expect(h.lock.value, isTrue);

      // Replace the viewer, as popping the route would.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pumpAndSettle();
      expect(
        h.lock.value,
        isFalse,
        reason: 'a latched lock would freeze paging for every later page',
      );
    });
  });
}
